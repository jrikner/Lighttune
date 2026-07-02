-- Color math domain tests (shared lua/color_math.lua + goals.QUALITY for rate_quality).

local color_math = require("color_math")
local goals = require("goals")

local cct_to_xy = color_math.cct_to_xy
local xy_to_uvp = color_math.xy_to_uvp
local uvp_to_xy = color_math.uvp_to_xy
local apply_duv_correction = color_math.apply_duv_correction
local xy_to_rgb = color_math.xy_to_rgb
local rgb_to_hsb = color_math.rgb_to_hsb
local rate_quality = color_math.rate_quality
local rate_duv = color_math.rate_duv
local gel_hint = color_math.gel_hint
local QUALITY = goals.QUALITY

return function(M)
    M.section("cct_to_xy – known reference values (Kang et al.)")
    do local x,y=cct_to_xy(3200); M.assert_near("3200K x",x,0.4232,0.005); M.assert_near("3200K y",y,0.3974,0.005) end
    do local x,y=cct_to_xy(5600); M.assert_near("5600K x",x,0.3301,0.005); M.assert_near("5600K y",y,0.3391,0.005) end
    do local x,y=cct_to_xy(6500); M.assert_near("6500K x",x,0.3135,0.005); M.assert_near("6500K y",y,0.3237,0.005) end
    do local x,y=cct_to_xy(4000); M.assert_near("4000K x (boundary)",x,0.3805,0.010); M.assert_near("4000K y (boundary)",y,0.3768,0.010) end

    M.section("xy_to_uvp / uvp_to_xy – roundtrip")
    do
        for _,tc in ipairs({{0.3127,0.3290},{0.4176,0.3814},{0.2500,0.2500}}) do
            local x0,y0=tc[1],tc[2]; local up,vp=xy_to_uvp(x0,y0); local x1,y1=uvp_to_xy(up,vp)
            M.assert_near(string.format("roundtrip x (%.4f,%.4f)",x0,y0),x1,x0,0.0001)
            M.assert_near(string.format("roundtrip y (%.4f,%.4f)",x0,y0),y1,y0,0.0001)
        end
    end

    M.section("apply_duv_correction – identity and direction")
    do local x0,y0=cct_to_xy(5600); local x1,y1=apply_duv_correction(x0,y0,0.003,0.003)
       M.assert_near("identity x",x1,x0,0.0001); M.assert_near("identity y",y1,y0,0.0001) end
    do local x0,y0=cct_to_xy(5600); local _,vp0=xy_to_uvp(x0,y0)
       local xc,yc=apply_duv_correction(x0,y0,0.005,0.000); local _,vpc=xy_to_uvp(xc,yc)
       if vpc<vp0 then print("  PASS  green correction shifts v' toward magenta"); M.PASS=M.PASS+1
       else print("  FAIL  green correction direction wrong"); M.FAIL=M.FAIL+1 end end

    M.section("xy_to_rgb / rgb_to_hsb")
    do local r,g,b=xy_to_rgb(0.3127,0.3290)
       M.assert_near("D65 R",r,1.0,0.05); M.assert_near("D65 G",g,1.0,0.05); M.assert_near("D65 B",b,1.0,0.05) end
    do local h,s,bri=rgb_to_hsb(1,0,0)
       M.assert_near("red H",h,0,1); M.assert_near("red S",s,1.0,0.001); M.assert_near("red B",bri,1.0,0.001) end
    do local h,s,bri=rgb_to_hsb(0,1,0)
       M.assert_near("green H",h,120,1) end
    do local h,s,bri=rgb_to_hsb(1,1,1)
       M.assert_near("white S",s,0.0,0.001); M.assert_near("white B",bri,1.0,0.001) end

    M.section("rate_quality – CRI/R9/TLCI/Duv boundaries")
    M.assert_equal("CRI 95=Excellent",  rate_quality(95,QUALITY.CRI),"Excellent")
    M.assert_equal("CRI 90=Good",       rate_quality(90,QUALITY.CRI),"Good")
    M.assert_equal("CRI 80=Acceptable", rate_quality(80,QUALITY.CRI),"Acceptable")
    M.assert_equal("CRI 79=Poor",       rate_quality(79,QUALITY.CRI),"Poor")
    M.assert_equal("R9  90=Excellent",  rate_quality(90,QUALITY.R9), "Excellent")
    M.assert_equal("R9  50=Acceptable", rate_quality(50,QUALITY.R9), "Acceptable")
    M.assert_equal("R9  49=Poor",       rate_quality(49,QUALITY.R9), "Poor")
    M.assert_equal("TLCI 90=Excellent", rate_quality(90,QUALITY.TLCI),"Excellent")
    M.assert_equal("TLCI 75=Good",      rate_quality(75,QUALITY.TLCI),"Good")
    M.assert_equal("TLCI 74=Acceptable",rate_quality(74,QUALITY.TLCI),"Acceptable")
    M.assert_equal("TLCI  0=Poor",      rate_quality(0, QUALITY.TLCI),"Poor")
    M.assert_equal("Duv 0.000=Excellent",rate_duv(0.000),"Excellent")
    M.assert_equal("Duv 0.003=Excellent",rate_duv(0.003),"Excellent")
    M.assert_equal("Duv 0.006=Good",     rate_duv(0.006),"Good")
    M.assert_equal("Duv 0.010=Acceptable",rate_duv(0.010),"Acceptable")
    M.assert_equal("Duv 0.011=Poor",     rate_duv(0.011),"Poor")
    M.assert_equal("Duv -0.011=Poor",    rate_duv(-0.011),"Poor")

    M.section("gel_hint – direction and amount")
    M.assert_equal("Duv 0.000=nil",  gel_hint(0.000),nil)
    M.assert_equal("Duv +0.003=nil", gel_hint(0.003),nil)
    do local h=gel_hint(0.004);  M.assert_equal("Duv +0.004=1/8 Minus",h and h:sub(1,11) or nil,"1/8 Minus G") end
    do local h=gel_hint(-0.004); M.assert_equal("Duv -0.004=1/8 Plus", h and h:sub(1,10) or nil,"1/8 Plus G")  end
    do local h=gel_hint(0.006);  M.assert_equal("Duv +0.006=1/8 (at boundary)",h and h:sub(1,11) or nil,"1/8 Minus G") end
    do local h=gel_hint(0.007);  M.assert_equal("Duv +0.007=1/4 Minus",h and h:sub(1,11) or nil,"1/4 Minus G") end
    do local h=gel_hint(0.012);  M.assert_equal("Duv +0.012=1/2 Minus",h and h:sub(1,11) or nil,"1/2 Minus G") end
    do local h=gel_hint(-0.012); M.assert_equal("Duv -0.012=1/2 Plus", h and h:sub(1,10) or nil,"1/2 Plus G")  end
    do local h=gel_hint(0.020);  M.assert_equal("Duv +0.020=Full Minus",h and h:sub(1,12) or nil,"Full Minus G") end
    do local h=gel_hint(-0.020); M.assert_equal("Duv -0.020=Full Plus", h and h:sub(1,11) or nil,"Full Plus G")  end
end
