local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Icons = require("modules/ui/icons")
local _ = require("gettext")

local QuickRSS = WidgetContainer:extend{
    name = "quickrss",
    is_doc_only = false,
}

function QuickRSS:init()
    self.ui.menu:registerToMainMenu(self)
end

function QuickRSS:addToMainMenu(menu_items)
    menu_items.quickrss = {
        text = Icons.FEEDS .. " " .. _("QuickRSS"),
        sorting_hint = "search",
        callback = function()
            -- .show() surfaces an already-open feed list/article reader
            -- instead of stacking a redundant duplicate on top of it.
            require("modules/ui/feed_view").show()
        end,
    }
end

return QuickRSS
