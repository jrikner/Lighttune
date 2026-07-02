-- ui/dialogs.lua — shared MessageBox input helpers (Phase 6)

local M = {}

function M.get_number_input(display, title, message, min_val, max_val)
    for attempt = 1, 3 do
        local prefix = attempt > 1
            and string.format("Value must be between %g and %g.\n\n", min_val, max_val) or ""
        local result = MessageBox({
            title=title, message=prefix..message, display_handle=display,
            input=true, buttons={"OK","Cancel"},
        })
        if result == nil or result == 2 then return nil end
        local num = tonumber(tostring(result))
        if num and num >= min_val and num <= max_val then return num end
    end
    return nil
end

function M.show_result(display, success, group, method, err_msg)
    if success then
        MessageBox({ title="Correction Applied",
            message=string.format("Correction applied to Group %s.\nMethod: %s\n\n"
                .."Re-measure with Sekonic meter to confirm.", group, method),
            display_handle=display, buttons={"OK"} })
    else
        MessageBox({ title="Apply Failed",
            message=string.format("Could not apply correction to Group %s.\n\nError: %s",
                group, tostring(err_msg)),
            display_handle=display, buttons={"OK"} })
    end
end

return M
