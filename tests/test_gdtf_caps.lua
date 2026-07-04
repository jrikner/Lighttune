local gdtf_caps = require("gdtf_caps")

return function(M)
    M.section("gdtf_caps.register_attribute")
    do
        local caps = gdtf_caps.new_caps()
        gdtf_caps.register_attribute(caps, "CTC", {
            ChannelFunctions = {
                Count = function() return 2 end,
                Child = function(_, i)
                    if i == 0 then return { PhysicalFrom = 3000, PhysicalTo = 6700, PhysicalUnit = "ColorTemperature" } end
                    return nil
                end,
            },
        })
        M.assert_equal("has CTC", caps.has_ctc, true)
        M.assert_equal("ctc attr", caps.ctc_attr, "CTC")
        M.assert_equal("kelvin min", caps.ctc_kelvin_min, 3000)
        M.assert_equal("kelvin max", caps.ctc_kelvin_max, 6700)
    end

    M.section("gdtf_caps.finalize_caps")
    do
        local c = gdtf_caps.finalize_caps(gdtf_caps.new_caps(), true)
        M.assert_equal("gdtf source", c.gdtf_source, false)
        M.assert_equal("no fake rgb", c.has_rgb, false)
    end
    do
        local c = gdtf_caps.finalize_caps(nil, false)
        M.assert_equal("fallback rgb", c.has_rgb, true)
        M.assert_equal("fallback source", c.source, "fallback_setcolor")
    end
end
