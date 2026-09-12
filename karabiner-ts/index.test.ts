import { strict as assert } from 'node:assert'
import { spawnSync } from 'node:child_process'
import { promises as fs } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, test } from 'node:test'

const projectDirectory = dirname(fileURLToPath(import.meta.url))
const temporaryHomes: string[] = []

async function createHome(config?: unknown): Promise<{ home: string; configPath: string; configDirectory: string }> {
  const home = await fs.mkdtemp(join(tmpdir(), 'karabiner-ts-test-'))
  temporaryHomes.push(home)

  const configDirectory = join(home, '.config', 'karabiner')
  const configPath = join(configDirectory, 'karabiner.json')

  if (config !== undefined) {
    await fs.mkdir(configDirectory, { recursive: true })
    await fs.writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`)
  }

  return { home, configPath, configDirectory }
}

function runGenerator(home: string, args: string[] = []) {
  const result = spawnSync(process.execPath, ['--import', 'tsx', 'index.ts', ...args], {
    cwd: projectDirectory,
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
    },
  })

  assert.equal(result.error, undefined, result.error?.message)
  return result
}

async function existingNames(directory: string): Promise<string[]> {
  try {
    return await fs.readdir(directory)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
}

async function readJson(path: string): Promise<Record<string, unknown>> {
  return JSON.parse(await fs.readFile(path, 'utf8')) as Record<string, unknown>
}

afterEach(async () => {
  while (temporaryHomes.length > 0) {
    const home = temporaryHomes.pop()
    if (home) await fs.rm(home, { recursive: true, force: true })
  }
})

test('missing Karabiner configuration fails before creating or writing a target', async () => {
  const { home, configPath, configDirectory } = await createHome()

  const result = runGenerator(home)

  assert.notEqual(result.status, 0)
  assert.match(`${result.stdout}\n${result.stderr}`, /Open Karabiner-Elements once and create the "Default profile" profile/)
  assert.deepEqual(await existingNames(configDirectory), [])
  await assert.rejects(fs.access(configPath))
})

test('missing Default profile fails without changing the fixture', async () => {
  const fixture = {
    global: { show_in_menu_bar: true },
    devices: [{ name: 'keyboard', ignored: false }],
    profiles: [{
      name: 'Work profile',
      selected: true,
      complex_modifications: { rules: [{ description: 'keep this profile' }] },
    }],
  }
  const { home, configPath, configDirectory } = await createHome(fixture)
  const original = await fs.readFile(configPath, 'utf8')

  const result = runGenerator(home)

  assert.notEqual(result.status, 0)
  assert.match(`${result.stdout}\n${result.stderr}`, /profile "Default profile" was not found/)
  assert.equal(await fs.readFile(configPath, 'utf8'), original)
  assert.deepEqual((await existingNames(configDirectory)).filter((name) => name.includes('.bak.')), [])
})

test('updates only Default profile complex modifications and is idempotent', async () => {
  const fixture = {
    global: { show_in_menu_bar: true, show_profile_name_in_menu_bar: false },
    devices: [{ name: 'keyboard', identifiers: { vendor_id: 1234 }, ignored: false }],
    custom_root_field: { keep: ['this', 'value'] },
    profiles: [
      {
        name: 'Work profile',
        selected: false,
        complex_modifications: { rules: [{ description: 'keep this profile' }] },
        custom_profile_field: 'keep',
      },
      {
        name: 'Default profile',
        selected: true,
        complex_modifications: { parameters: { old: true }, rules: [{ description: 'replace this' }] },
        simple_modifications: [{ from: { key_code: 'a' }, to: [{ key_code: 'b' }] }],
        devices: [{ name: 'profile keyboard', ignored: true }],
      },
    ],
  }
  const { home, configPath, configDirectory } = await createHome(fixture)
  const original = await fs.readFile(configPath, 'utf8')

  const first = runGenerator(home)

  assert.equal(first.status, 0, first.stderr)
  const updated = await readJson(configPath)
  assert.deepEqual(updated.global, fixture.global)
  assert.deepEqual(updated.devices, fixture.devices)
  assert.deepEqual(updated.custom_root_field, fixture.custom_root_field)
  const profiles = updated.profiles as Array<Record<string, unknown>>
  assert.deepEqual(profiles[0], fixture.profiles[0])

  const defaultProfile = profiles[1]
  assert.equal(defaultProfile.name, 'Default profile')
  assert.equal(defaultProfile.selected, true)
  assert.deepEqual(defaultProfile.simple_modifications, fixture.profiles[1].simple_modifications)
  assert.deepEqual(defaultProfile.devices, fixture.profiles[1].devices)
  assert.ok((defaultProfile.complex_modifications as { rules: unknown[] }).rules.length > 0)
  assert.notDeepEqual(defaultProfile.complex_modifications, fixture.profiles[1].complex_modifications)

  let backups = (await existingNames(configDirectory)).filter((name) => name.startsWith('karabiner.json.bak.'))
  assert.equal(backups.length, 1)
  assert.equal(await fs.readFile(join(configDirectory, backups[0]), 'utf8'), original)

  const second = runGenerator(home)

  assert.equal(second.status, 0, second.stderr)
  assert.match(second.stdout, /already up to date/)
  assert.deepEqual(await readJson(configPath), updated)
  backups = (await existingNames(configDirectory)).filter((name) => name.startsWith('karabiner.json.bak.'))
  assert.equal(backups.length, 1)
})

test('updates a symlink target atomically while retaining the link and mode', async () => {
  const fixture = {
    profiles: [{
      name: 'Default profile',
      selected: true,
      complex_modifications: { rules: [] },
    }],
  }
  const { home, configPath, configDirectory } = await createHome()
  const storedPath = join(configDirectory, 'stored-karabiner.json')
  const original = `${JSON.stringify(fixture, null, 2)}\n`
  await fs.mkdir(configDirectory, { recursive: true })
  await fs.writeFile(storedPath, original, { mode: 0o640 })
  await fs.chmod(storedPath, 0o640)
  const originalStat = await fs.stat(storedPath)
  await fs.symlink(basename(storedPath), configPath)

  const result = runGenerator(home)

  assert.equal(result.status, 0, result.stderr)
  assert.ok((await fs.lstat(configPath)).isSymbolicLink())
  const updatedStat = await fs.stat(storedPath)
  assert.equal(updatedStat.mode & 0o7777, originalStat.mode & 0o7777)
  assert.equal(updatedStat.uid, originalStat.uid)
  assert.equal(updatedStat.gid, originalStat.gid)
  const updated = await readJson(storedPath)
  const updatedProfile = (updated.profiles as Array<Record<string, unknown>>)[0]
  assert.notDeepEqual(updatedProfile, fixture.profiles[0])
  const backups = (await existingNames(configDirectory)).filter((name) => name.startsWith('karabiner.json.bak.'))
  assert.equal(backups.length, 1)
  assert.equal(await fs.readFile(join(configDirectory, backups[0]), 'utf8'), original)
  const backupStat = await fs.stat(join(configDirectory, backups[0]))
  assert.equal(backupStat.mode & 0o7777, originalStat.mode & 0o7777)
  assert.equal(backupStat.uid, originalStat.uid)
  assert.equal(backupStat.gid, originalStat.gid)
})

function readXattr(path: string, name: string): string {
  const result = spawnSync('/usr/bin/xattr', ['-p', name, path], { encoding: 'utf8' })
  assert.equal(result.error, undefined, result.error?.message)
  assert.equal(result.status, 0, result.stderr)
  return result.stdout.trimEnd()
}

test('preserves a macOS extended attribute on the target and backup', { skip: process.platform !== 'darwin' }, async () => {
  const fixture = {
    profiles: [{
      name: 'Default profile',
      selected: true,
      complex_modifications: { rules: [] },
    }],
  }
  const { home, configPath, configDirectory } = await createHome()
  const storedPath = join(configDirectory, 'stored-karabiner.json')
  const original = `${JSON.stringify(fixture, null, 2)}\n`
  const attributeName = 'user.kayg.karabiner-test'
  const attributeValue = 'metadata-value'
  await fs.mkdir(configDirectory, { recursive: true })
  await fs.writeFile(storedPath, original, { mode: 0o640 })
  await fs.chmod(storedPath, 0o640)
  await fs.symlink(basename(storedPath), configPath)

  const setAttribute = spawnSync('/usr/bin/xattr', ['-w', attributeName, attributeValue, storedPath], { encoding: 'utf8' })
  assert.equal(setAttribute.error, undefined, setAttribute.error?.message)
  assert.equal(setAttribute.status, 0, setAttribute.stderr)

  const result = runGenerator(home)

  assert.equal(result.status, 0, result.stderr)
  assert.equal(readXattr(storedPath, attributeName), attributeValue)
  const backups = (await existingNames(configDirectory)).filter((name) => name.startsWith('karabiner.json.bak.'))
  assert.equal(backups.length, 1)
  assert.equal(readXattr(join(configDirectory, backups[0]), attributeName), attributeValue)
})

test('--check validates only generated memory output', async () => {
  const { home, configDirectory } = await createHome()

  const result = runGenerator(home, ['--check'])

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /In-memory Karabiner output check passed/)
  assert.deepEqual(await existingNames(configDirectory), [])
})
