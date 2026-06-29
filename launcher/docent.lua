-- docent launcher (macOS / Hammerspoon) -- a Spotlight-style chooser bound to a
-- global hotkey. Type to filter your docent sessions / tickets / PRs; Enter
-- focuses the session window (POST /focus) or opens the ticket/PR URL.
--
-- Install: copy this file next to your ~/.hammerspoon/init.lua and add:
--     require("docent")
-- then reload Hammerspoon. Default hotkey: Cmd+Alt+Space (edit DOCENT.hotkey).

local DOCENT = {
  port = tonumber(os.getenv("DOCENT_PORT")) or 39787,
  token = os.getenv("DOCENT_TOKEN"),
  hotkey = { mods = { "cmd", "alt" }, key = "space" },
}
local base = "http://127.0.0.1:" .. DOCENT.port

local chooser = nil

-- Flatten GET /sessions into chooser rows.
local function buildChoices(data, cb)
  local choices = {}
  for _, g in ipairs(data.groups or {}) do
    local ticket = g.ticket
    for _, s in ipairs(g.sessions or {}) do
      local subParts = {}
      if ticket then table.insert(subParts, ticket) end
      if s.host then table.insert(subParts, s.host) end
      if s.needsFollowup then table.insert(subParts, "● follow-up")
      elseif not s.live then table.insert(subParts, "closed") end
      table.insert(choices, {
        text = s.name,
        subText = table.concat(subParts, "  ·  "),
        kind = "session", name = s.name, sort = s.needsFollowup and 0 or (s.live and 1 or 2),
      })
    end
    for _, pr in ipairs(g.prs or {}) do
      table.insert(choices, {
        text = "PR #" .. tostring(pr.prNumber) .. "  " .. (pr.title or ""),
        subText = table.concat({ ticket or "", pr.repo or "", pr.state or "" }, "  ·  "),
        kind = "url", url = pr.url, sort = 3,
      })
    end
    if ticket and #(g.sessions or {}) == 0 and #(g.prs or {}) == 0 and g.jiraUrl then
      table.insert(choices, {
        text = ticket .. "  " .. (g.summary or ""),
        subText = g.jiraStatus or "",
        kind = "url", url = g.jiraUrl, sort = 4,
      })
    end
  end
  table.sort(choices, function(a, b) return (a.sort or 9) < (b.sort or 9) end)
  cb(choices)
end

local function activate(choice)
  if not choice then return end
  if choice.kind == "session" then
    local headers = { ["Content-Type"] = "application/json" }
    if DOCENT.token then headers["Authorization"] = "Bearer " .. DOCENT.token end
    hs.http.asyncPost(base .. "/focus", hs.json.encode({ name = choice.name }), headers,
      function(_, _, _) end)
  elseif choice.kind == "url" and choice.url then
    hs.urlevent.openURL(choice.url)
  end
end

local function show()
  hs.http.asyncGet(base .. "/sessions", nil, function(status, body, _)
    local choices = {}
    if status == 200 and body then
      local ok, data = pcall(hs.json.decode, body)
      if ok and data then buildChoices(data, function(c) choices = c end) end
    end
    if not chooser then
      chooser = hs.chooser.new(activate)
      chooser:searchSubText(true)
    end
    chooser:choices(choices)
    chooser:query("")
    chooser:show()
  end)
end

hs.hotkey.bind(DOCENT.hotkey.mods, DOCENT.hotkey.key, show)

return DOCENT
