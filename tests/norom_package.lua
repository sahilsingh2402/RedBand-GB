-- The ROM-free package (for publishing): the Poketch clock, BROWSE and the face work; POWER
-- explains that there is no game ROM.
if not arg[1] then error("usage: bandhost32 0 tests/norom_package.lua <unpacked noROM app>/") end
local T = dofile('tests/common.lua')
local mock, R = T.load(arg[1], {})
mock.refresh()
assert(not R.clockPanel.flags[mock.FLAG.HIDDEN], 'clock not shown')
mock.fire(R.power, mock.EVENT.CLICKED)
assert(R.emu() == nil and R.msg().props.text == 'no game ROM in this watchface', 'no-ROM message: ' .. tostring(R.msg().props.text))
mock.fire(R.browse, mock.EVENT.CLICKED)
assert(not R.browser.flags[mock.FLAG.HIDDEN], 'BROWSE does not open')
print('ROM-free package OK: Poketch clock, BROWSE, POWER says "' .. R.msg().props.text .. '", nothing breaks')
