import {
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
  writeToProfile,
} from 'karabiner.ts'

writeToProfile('kayg-primary', [
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
], {
  'duo_layer.threshold_milliseconds': 100,
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
      map('y').to('left_arrow', 'left_command'),
      // move cursor down by one page
      map('u').to('down_arrow', 'fn'),
      // move cursor up by one page
      map('i').to('up_arrow', 'fn'),
      // move cursor to the end of the line
      map('o').to('right_arrow', 'left_command'),

      // arrow keys, inspired by Max Stoiber and vim
      map('h').to('left_arrow', 'left_shift'),
      map('j').to('down_arrow', 'left_shift'),
      map('k').to('up_arrow', 'left_shift'),
      map('l').to('right_arrow', 'left_shift'),
      map(';').to('delete_or_backspace'),

      // move left by one word
      map('n').to('left_arrow', ['left_option', 'left_shift']),
      // move to the beginning and end of the document
      map('m').to('up_arrow', ['left_option', 'left_shift']),
      map(',').to('down_arrow', ['left_option', 'left_shift']),
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