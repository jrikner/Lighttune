-- ui/history.lua — fixture history viewer (Phase 6)

local fixture_db = require("fixture_db")

local M = {}

local STAR = "\xe2\x98\x85"

function M.show_fixture_history(display, data_dir)
    local sep = "/"
    pcall(function() sep = GetPathSeparator() end)
    local path = data_dir..sep.."fixture_log.json"

    local records = {}
    local f = io.open(path,"r")
    if f then
        local content = f:read("*a"); f:close()
        local skipped, errors
        records, skipped, errors = fixture_db.json_parse_db_array(content)
        if skipped and skipped > 0 then
            MessageBox({ title="Fixture History", message=string.format(
                "Warning: %d malformed record(s) skipped in fixture_log.json.", skipped),
                display_handle=display, buttons={"OK"} })
        end
    end

    if #records==0 then
        MessageBox({ title="Fixture History", message="No fixture measurements logged yet.\n\nCalibrate some fixtures first.",
            display_handle=display, buttons={"OK"} })
        return
    end

    local fixtures, seen = {}, {}
    for _, rec in ipairs(records) do
        local key=(rec.make or "?").."|"..(rec.model or "?")
        if not seen[key] then
            seen[key]=true
            fixtures[#fixtures+1]={make=rec.make, model=rec.model}
        end
    end

    local list_str = {}
    for _, fx in ipairs(fixtures) do
        list_str[#list_str+1]=(fx.make or "?").." "..(fx.model or "?")
    end
    local search_r = MessageBox({ title="Fixture History",
        message=string.format("Logged fixtures (%d):\n\n%s\n\nEnter make/model to view (or part of the name):",
            #fixtures, table.concat(list_str,"\n")),
        display_handle=display, input=true, buttons={"Search","Cancel"} })
    if search_r==nil or search_r==2 then return end
    local search = tostring(search_r):match("^%s*(.-)%s*$"):lower()

    local matches={}
    for _, rec in ipairs(records) do
        local full=((rec.make or "").." "..(rec.model or "")):lower()
        if search=="" or full:find(search,1,true) then matches[#matches+1]=rec end
    end
    if #matches==0 then
        MessageBox({ title="Not Found", message="No records found for: "..search,
            display_handle=display, buttons={"OK"} })
        return
    end

    local kelvin_groups, kelvin_order, seen_k = {}, {}, {}
    for _, rec in ipairs(matches) do
        local k=rec.kelvin or 0
        if not seen_k[k] then seen_k[k]=true; kelvin_order[#kelvin_order+1]=k end
        if not kelvin_groups[k] then kelvin_groups[k]={} end
        kelvin_groups[k][#kelvin_groups[k]+1]=rec
    end
    table.sort(kelvin_order)

    local hdr_rec = matches[1]
    local hdr = string.format("%s %s", hdr_rec.make or "?", hdr_rec.model or "?")

    for _, k in ipairs(kelvin_order) do
        local entries = kelvin_groups[k]
        local lines = {
            string.format("%s @ %dK — %d measurement%s\n",
                hdr, k, #entries, #entries==1 and "" or "s"),
            string.format("%-10s  %-12s  %-6s %-6s %-6s %s",
                "Date","Contributor","CRI","R9","TLCI","Duv"),
            ("-"):rep(54),
        }
        for _, rec in ipairs(entries) do
            local function fv(v, best)
                if v==nil then return "  -- " end
                return string.format("%3d%s", v, best and STAR or " ")
            end
            local duv_s = rec.duv~=nil
                and string.format("%+.3f%s", rec.duv, rec.best_duv and STAR or " ")
                or "   --"
            lines[#lines+1]=string.format("%-10s  %-12s  %-6s%-6s%-6s %s",
                rec.date or "?", rec.contributor or "?",
                fv(rec.cri, rec.best_cri), fv(rec.r9, rec.best_r9),
                rec.tlci~=nil and fv(rec.tlci, rec.best_tlci) or "  -- ",
                duv_s)
        end
        lines[#lines+1]="\n"..STAR.." = best measurement for this fixture/kelvin"
        MessageBox({ title=string.format("Fixture History – %s @ %dK", hdr, k),
            message=table.concat(lines,"\n"), display_handle=display, buttons={"OK"} })
    end
end

return M
