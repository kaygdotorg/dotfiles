import { execFile as execFileCallback } from 'node:child_process'
import { promises as fs, type Stats } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { promisify } from 'node:util'

import {
  complexModifications,
  duoLayer,
  hyperLayer,
  ifVar,
  layer,
  map,
  modifierLayer,
  NumberKeyValue,
  rule,
  simlayer,
  toApp,
  withMapper,
  withModifier,
} from 'karabiner.ts'

const PROFILE_NAME = 'Default profile'

type JsonObject = Record<string, unknown>

const execFile = promisify(execFileCallback)

function isJsonObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function karabinerConfigPath(): string {
  return join(homedir(), '.config', 'karabiner', 'karabiner.json')
}

function errorCode(error: unknown): string | undefined {
  return isJsonObject(error) && typeof error.code === 'string' ? error.code : undefined
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function missingConfigMessage(configPath: string): string {
  return `Karabiner configuration was not found at ${configPath}. Open Karabiner-Elements once and create the "${PROFILE_NAME}" profile, then run this command again.`
}

async function readKarabinerConfig(configPath: string): Promise<{
  config: JsonObject
  profile: JsonObject
  resolvedPath: string
  originalStat: Stats
}> {
  let resolvedPath: string

  try {
    const linkStat = await fs.lstat(configPath)
    if (!linkStat.isFile() && !linkStat.isSymbolicLink()) {
      throw new Error(`The Karabiner configuration path ${configPath} is not a regular file.`)
    }

    resolvedPath = await fs.realpath(configPath)
  } catch (error) {
    if (errorCode(error) === 'ENOENT') {
      throw new Error(missingConfigMessage(configPath))
    }

    throw new Error(`Unable to resolve the Karabiner configuration at ${configPath}: ${errorMessage(error)}`)
  }

  let originalStat: Stats
  let source: string

  try {
    originalStat = await fs.stat(resolvedPath)
    if (!originalStat.isFile()) {
      throw new Error(`The Karabiner configuration path ${configPath} is not a regular file.`)
    }
    source = await fs.readFile(resolvedPath, 'utf8')
  } catch (error) {
    throw new Error(`Unable to read the Karabiner configuration at ${configPath}: ${errorMessage(error)}`)
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(source)
  } catch (error) {
    throw new Error(`The Karabiner configuration at ${configPath} is not valid JSON: ${errorMessage(error)}`)
  }

  if (!isJsonObject(parsed) || !Array.isArray(parsed.profiles)) {
    throw new Error(`The Karabiner configuration at ${configPath} has no profiles array. Open Karabiner-Elements and create the "${PROFILE_NAME}" profile, then run this command again.`)
  }

  const profile = parsed.profiles.find((candidate): candidate is JsonObject => (
    isJsonObject(candidate) && candidate.name === PROFILE_NAME
  ))

  if (!profile) {
    throw new Error(`Karabiner profile "${PROFILE_NAME}" was not found in ${configPath}. Open Karabiner-Elements, create or rename that profile, then run this command again.`)
  }

  return { config: parsed, profile, resolvedPath, originalStat }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await fs.lstat(path)
    return true
  } catch (error) {
    if (errorCode(error) === 'ENOENT') return false
    throw error
  }
}

async function copyPreservingMetadata(source: string, destination: string): Promise<boolean> {
  if (process.platform === 'darwin') {
    await execFile('/bin/cp', ['-p', source, destination])
    return true
  }

  if (process.platform === 'linux') {
    await execFile('/bin/cp', ['--preserve=all', source, destination])
    return true
  }

  await fs.copyFile(source, destination)
  return false
}

async function writeCopiedFile(path: string, content: string, originalMode: number): Promise<void> {
  try {
    await fs.writeFile(path, content, 'utf8')
    return
  } catch (error) {
    const code = errorCode(error)
    if (code !== 'EACCES' && code !== 'EPERM') throw error
  }

  // A read-only source can still be replaced atomically through its writable
  // directory. Temporarily grant the owner write access to the copied inode,
  // then restore the exact mode before the rename.
  await fs.chmod(path, originalMode | 0o200)
  try {
    await fs.writeFile(path, content, 'utf8')
  } finally {
    await fs.chmod(path, originalMode)
  }
}

async function nextBackupPath(configPath: string): Promise<string> {
  const timestamp = new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 14)
  const prefix = `${configPath}.bak.${timestamp}`
  let candidate = prefix
  let attempt = 0

  while (await pathExists(candidate)) {
    attempt += 1
    candidate = `${prefix}.${attempt}`
  }

  return candidate
}

async function backupConfig(configPath: string, resolvedPath: string, originalStat: Stats): Promise<string> {
  const backupPath = await nextBackupPath(configPath)
  const mode = originalStat.mode & 0o7777

  try {
    const metadataCopied = await copyPreservingMetadata(resolvedPath, backupPath)
    if (!metadataCopied) {
      await fs.chmod(backupPath, mode)
      await fs.utimes(backupPath, originalStat.atime, originalStat.mtime)
    }
  } catch (error) {
    await fs.rm(backupPath, { force: true })
    throw new Error(`Unable to back up ${configPath} to ${backupPath}: ${errorMessage(error)}`)
  }

  return backupPath
}

async function writeConfigAtomically(resolvedPath: string, content: string, originalStat: Stats): Promise<void> {
  // Rename the resolved target so a karabiner.json symlink remains intact. The
  // replacement keeps the original permission bits; its contents and mtime
  // intentionally change when the generated profile changes.
  const temporaryDirectory = await fs.mkdtemp(join(dirname(resolvedPath), `.${basename(resolvedPath)}.tmp-`))
  const temporaryPath = join(temporaryDirectory, basename(resolvedPath))
  const mode = originalStat.mode & 0o7777

  try {
    const metadataCopied = await copyPreservingMetadata(resolvedPath, temporaryPath)
    if (!metadataCopied) {
      await fs.chmod(temporaryPath, mode)
      await fs.utimes(temporaryPath, originalStat.atime, originalStat.mtime)
    }
    await writeCopiedFile(temporaryPath, content, mode)
    await fs.rename(temporaryPath, resolvedPath)
  } finally {
    await fs.rm(temporaryDirectory, { recursive: true, force: true })
  }
}

const profileRules = [
  navigationLayer(),
  selectLayer(),
  numberLayer(),
  symbolLayer(),
  functionKeyLayer(),
  applicationLayer(),
  raycastLayer(),
  windowManagementLayer(),
  essentialModifiers(),
  qwertyToColemakDH(),
]

const profileParameters = {
  'duo_layer.threshold_milliseconds': 100,
}

function generatedOutput() {
  return complexModifications(profileRules, profileParameters)
}

function assertToModifierArrays(value: unknown): void {
  if (Array.isArray(value)) {
    value.forEach(assertToModifierArrays)
    return
  }

  if (value === null || typeof value !== 'object') return

  const record = value as Record<string, unknown>
  if ('modifiers' in record && !Array.isArray(record.modifiers)) {
    throw new Error('Generated Karabiner output contains a non-array modifiers value')
  }

  Object.entries(record).forEach(([key, child]) => {
    if (key !== 'modifiers') assertToModifierArrays(child)
  })
}

function assertGeneratedToModifierArrays(value: unknown): void {
  if (Array.isArray(value)) {
    value.forEach(assertGeneratedToModifierArrays)
    return
  }

  if (value === null || typeof value !== 'object') return

  const eventLists = new Set(['to', 'to_if_alone', 'to_if_held_down', 'to_after_key_up'])
  Object.entries(value as Record<string, unknown>).forEach(([key, child]) => {
    if (eventLists.has(key)) {
      assertToModifierArrays(child)
    } else {
      assertGeneratedToModifierArrays(child)
    }
  })
}

function checkGeneratedOutput(): void {
  const generated = generatedOutput()
  const serialized = JSON.stringify(generated)
  assertGeneratedToModifierArrays(JSON.parse(serialized))

  if (generated.rules.length === 0 || generated.rules.some(({ manipulators }) => manipulators.length === 0)) {
    throw new Error('Generated Karabiner output contains no-op rules')
  }

  const expectedMappings = [
    ['y', 'left_arrow', ['left_command', 'left_shift']],
    ['u', 'down_arrow', ['fn', 'left_shift']],
    ['i', 'up_arrow', ['fn', 'left_shift']],
    ['o', 'right_arrow', ['left_command', 'left_shift']],
  ] as const

  for (const [fromKey, toKey, modifiers] of expectedMappings) {
    const found = generated.rules.some(({ manipulators }) => manipulators.some((manipulator) => {
      if (manipulator.type !== 'basic' || !('key_code' in manipulator.from) || manipulator.from.key_code !== fromKey) {
        return false
      }

      return (manipulator.to ?? []).some((event) => (
        'key_code' in event &&
        event.key_code === toKey &&
        JSON.stringify(event.modifiers ?? []) === JSON.stringify(modifiers)
      ))
    }))

    if (!found) {
      throw new Error(`Missing generated mapping ${fromKey} -> ${toKey}`)
    }
  }

  const manipulatorCount = generated.rules.reduce((count, { manipulators }) => count + manipulators.length, 0)
  console.info(`✓ In-memory Karabiner output check passed (${generated.rules.length} rules, ${manipulatorCount} manipulators)`)
}

async function updateProfile(): Promise<void> {
  const configPath = karabinerConfigPath()
  const { config, profile, resolvedPath, originalStat } = await readKarabinerConfig(configPath)
  const generated = generatedOutput()

  if (JSON.stringify(profile.complex_modifications) === JSON.stringify(generated)) {
    console.info(`✓ Profile ${PROFILE_NAME} is already up to date.`)
    return
  }

  profile.complex_modifications = generated
  const content = `${JSON.stringify(config, null, 2)}\n`
  const backupPath = await backupConfig(configPath, resolvedPath, originalStat)
  await writeConfigAtomically(resolvedPath, content, originalStat)

  console.info(`✓ Profile ${PROFILE_NAME} updated.`)
  console.info(`  Backup: ${backupPath}`)
}

async function main(): Promise<void> {
  if (process.argv.includes('--check')) {
    checkGeneratedOutput()
    return
  }

  await updateProfile()
}

main().catch((error: unknown) => {
  console.error(`✗ ${errorMessage(error)}`)
  process.exitCode = 1
})

/* I am using Colemak-DH MATRIX on MacOS so apart from the navigation layer, everything else might seem odd.
That's because Karabiner Elements recognizes keycodes from the physical keyboard and then they go to MacOS.
That means that the keys' physical location matters. If I want colemak DH specific keys then I need to use the
key on the physical keyboard that corresponds to COLEMAK DH on QWERTY. Here's a map:
 
  a → a
  b → t
  c → c
  d → s
  e → f
  f → b
  ...

Here's QWERTY: https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/Apple_Magic_Keyboard_-_US_remix_transparent.png/1394px-Apple_Magic_Keyboard_-_US_remix_transparent.png
Here's Colemak DH: https://colemakmods.github.io/mod-dh/gfx/about/colemak_dh_main_matrix.png
*/

function applicationLayer() {
  return hyperLayer('a')
    .description('Application layer')
    .notification()
    .manipulators([
      // switch apps
      map('tab').to$("open -g 'raycast://extensions/raycast/navigation/switch-windows'"),
      // middle row - most commonly used apps
      map('m').toApp("1Password"),
      map('h').toApp("Safari"),
      map('j').toApp("iTerm"),
      map('k').toApp("Cursor"),
      map('l').toApp("Notes"),
      map(';').to$("open -g 'btt://trigger_named/?trigger_name=Open Apple Music → Search'"),
    ])
}

function essentialModifiers() {
  return rule('Essential Modifiers').manipulators([
    // 
    // Tab → Meh                                                         ] → Meh
    // Caps → Hyper                                                      " → Hyper
    //                                                                   / → Left Control
    //            Left ⌘ → Esc                     Right ⌘ → Left Option

    // left hand - contains 4 modifier and 3 modifier combinations
    map('grave_accent_and_tilde').to('left_command', ['left_option', 'left_control']).toIfAlone('grave_accent_and_tilde'),
    map('tab').toMeh().toIfAlone('tab'),
    map('caps_lock').toHyper().toIfAlone('escape'),
    map('left_command').to('left_command').toIfAlone('escape'),

    // --- right hand ---
    // top row - starts with left_option
    map('[').to('left_option', 'left_shift').toIfAlone('['),
    map(']').to('left_option', 'left_control').toIfAlone(']'),

    // middle row - starts with left_control
    map('quote').to('left_control', 'left_shift').toIfAlone('quote'),

    // bottom row - starts with left_command
    map('slash').to('left_command', 'left_option').toIfAlone('slash'),
    map('.').to('left_command', 'left_control').toIfAlone('.'),
    map(',').to('left_command', 'left_shift').toIfAlone(','),

    // the very bottom row
    map('right_command').to('left_option').toIfAlone('delete_or_backspace'),
  ])
}

function functionKeyLayer() {
  return hyperLayer('c')
    .notification()
    .description('Function Key Layer')
    .manipulators([
      // F9 F10 F11 F12
      // u   i   o   p
      map('u').to('f9'),
      map('i').to('f10'),
      map('o').to('f11'),
      map('p').to('f12'),

      // 4 5 6 = 
      // j k l ;
      map('j').to('f5'),
      map('k').to('f6'),
      map('l').to('f7'),
      map(';').to('f8'),

      // 0 1 2 3 
      // m , . /
      map('m').to('f1'),
      map(',').to('f2'),
      map('.').to('f3'),
      map('/').to('f4'),
    ])
}

// mediaLayer is intentionally excluded from writeToProfile.
// hyper+m is not registered, so this layer is dormant.
// Keeping the definition here for reference / future re-activation.
function mediaLayer() {
  return hyperLayer('m')
    .notification()
    .description('Media Layer')
    .manipulators([
      map('w').to('volume_up'),
      map('s').to('volume_down'),
      map('d').to('vk_consumer_previous'),
      map('spacebar').to('play_or_pause'),
    ])
}

function selectLayer() {
  return hyperLayer('v')
    .description('Select Layer')
    .notification()
    .manipulators([
      // left half of the keyboard //

      // -- right half of the keyboard -- //
      // move cursor to the beginning of the line
      map('y').to('left_arrow', ['left_command', 'left_shift']),
      // move cursor down by one page
      map('u').to('down_arrow', ['fn', 'left_shift']),
      // move cursor up by one page
      map('i').to('up_arrow', ['fn', 'left_shift']),
      // move cursor to the end of the line
      map('o').to('right_arrow', ['left_command', 'left_shift']),

      // arrow keys, inspired by Max Stoiber and vim
      map('h').to('left_arrow', 'left_shift'),
      map('j').to('down_arrow', 'left_shift'),
      map('k').to('up_arrow', 'left_shift'),
      map('l').to('right_arrow', 'left_shift'),
      map(';').to('delete_or_backspace'),

      // move left by one word
      map('n').to('left_arrow', ['left_option', 'left_shift']),
      // move to the beginning and end of the document
      map('m').to('up_arrow', ['left_command', 'left_shift']),
      map(',').to('down_arrow', ['left_command', 'left_shift']),
      // move right by one word
      map('.').to('right_arrow', ['left_option', 'left_shift']),

    ])
}

function navigationLayer() {
  return hyperLayer('spacebar')
    .description('Navigation Layer')
    .notification()
    .manipulators([
      // left half of the keyboard //

      // -- right half of the keyboard -- //
      // move cursor to the beginning of the line
      map('y').to('left_arrow', 'left_command'),
      // move cursor down by one page
      map('u').to('down_arrow', 'fn'),
      // move cursor up by one page
      map('i').to('up_arrow', 'fn'),
      // move cursor to the end of the line
      map('o').to('right_arrow', 'left_command'),

      // arrow keys, inspired by Max Stoiber and vim
      map('h').to('left_arrow'),
      map('j').to('down_arrow'),
      map('k').to('up_arrow'),
      map('l').to('right_arrow'),
      map(';').to('delete_or_backspace'),

      // move left by one word
      map('n').to('left_arrow', 'left_option'),
      // move to the beginning and end of the document
      map('m').to('up_arrow', 'left_command'),
      map(',').to('down_arrow', 'left_command'),
      // move right by one word
      map('.').to('right_arrow', 'left_option'),

    ])
}

function numberLayer() {
  return hyperLayer('z')
  .description('Number Pad Layer')
  .notification()
  .manipulators([
    // implement numpad on the left hand side

    // 7 8 9 -
    // u i o p
    map('u').to('7'),
    map('i').to('8'),
    map('o').to('9'),
    map('p').to('-'),

    // 4 5 6 = 
    // j k l ;
    map('j').to('4'),
    map('k').to('5'),
    map('l').to('6'),
    map(';').to('='),

    // 0 1 2 3 
    // n m , .
    map('n').to('0'),
    map('m').to('1'),
    map(',').to('2'),
    map('.').to('3'),
  ])
}

function raycastLayer() {
  return hyperLayer('q')
    .description('Raycast Layer')
    .notification()
    .manipulators([
      map(';').to$('open raycast://extensions/benvp/audio-device/set-output-device'),
      map('l').to$('open raycast://extensions/benvp/audio-device/set-input-device'),
      map('r').to$('open raycast://extensions/raycast/typing-practice/start-typing-practice'),
    ])
}

function qwertyToColemakDH() {
  return rule('Colemak DH').manipulators([
    withModifier('optionalAny')([
      // top row
      map('q').to('q'),
      map('w').to('w'),
      map('e').to('f'),
      map('r').to('p'),
      map('t').to('b'),
      map('y').to('j'),
      map('u').to('l'),
      map('i').to('u'),
      map('o').to('y'),
      map('p').to(';'),
      // middle row
      map('a').to('a'),
      map('s').to('r'),
      map('d').to('s'),
      map('f').to('t'),
      map('g').to('g'),
      map('h').to('m'),
      map('j').to('n'),
      map('k').to('e'),
      map('l').to('i'),
      map(';').to('o'),
      // bottom row
      map('z').to('z'),
      map('x').to('x'),
      map('c').to('c'),
      map('v').to('d'),
      map('b').to('v'),
      map('n').to('k'),
      map('m').to('h'),
    ]),
  ])
}

function symbolLayer() {
  return hyperLayer('x')
    .description('Symbol Layer')
    .notification()
    .manipulators([
      // implement numpad on the left hand side

      // & * ( _
      // u i o p
      map('u').to('7', 'left_shift'),
      map('i').to('8', 'left_shift'),
      map('o').to('9', 'left_shift'),
      map('p').to('-', 'left_shift'),

      // 4 5 6 = 
      // j k l ;
      map('j').to('4', 'left_shift'),
      map('k').to('5', 'left_shift'),
      map('l').to('6', 'left_shift'),
      map(';').to('=', 'left_shift'),

      // 0 1 2 3 
      // n m , .
      map('n').to('0', 'left_shift'),
      map('m').to('1', 'left_shift'),
      map(',').to('2', 'left_shift'),
      map('.').to('3', 'left_shift'),
    ])
}

function windowManagementLayer() {
  return hyperLayer('w')
    .notification()
    .description('Window Management Layer')
    .manipulators([
      // Top 30%
      map('y').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Top Major Left'"),
      map('p').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Top Major Right'"),

      // Bottom 70%
      map('h').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Major Left'"),
      map('j').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Minor Left'"),
      map('k').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Major Center'"),
      map('l').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Minor Right'"),
      map(';').to$("open -g 'btt://trigger_named/?trigger_name=Move/Resize: Major Right'"),

      // maximise
      map('n').to$("open -g 'raycast://extensions/raycast/window-management/almost-maximize'"),
      map('m').to$("open -g 'raycast://extensions/raycast/window-management/maximize'"),
      map(',').to$("open -g 'raycast://extensions/raycast/window-management/left-half'"),
      map('.').to$("open -g 'raycast://extensions/raycast/window-management/right-half'"),
    ])
}
