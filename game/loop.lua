--- Common game loop logic.

--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
--

-- Standard library imports --
local assert = assert
local error = error
local setmetatable = setmetatable
local traceback = debug.traceback
local type = type
local yield = coroutine.yield

-- Modules --
--local bind = require("solar2d_utils.bind")
local call = require("solar2d_utils.call")
local game_loop_config = require("config.GameLoop")
local persistence = require("solar2d_utils.persistence")
local pubsub = require("solar2d_utils.pubsub")
local timers = require("solar2d_utils.timers")

-- Corona globals --
local Runtime = Runtime
local timer = timer

-- Corona modules --
local composer = require("composer")

-- Exports --
local M = {}

--
--
--

-- Limit runaway actions.
--[[bind]]call.SetActionLimit(game_loop_config.action_limit)

-- Return-to scene, during normal play... --
local NormalReturnTo = game_loop_config.normal_return_to

-- ...if the level was launched from the editor... --
local TestingReturnTo = game_loop_config.testing_return_to

-- ...or from the intro / title screen... --
local QuickTestReturnTo = game_loop_config.quick_test_return_to

-- ...the current return-to scene in effect  --
local ReturnTo

-- Helper to call a possibly non-existent function
local function Call (func, ...)
	if func then
		return func(...)
	end
end

local ShowOverlayEvent = { name = "show_overlay", isModal = true }

-- Cues an overlay scene
local function DoOverlay (name, on_done, params)
	if name and ReturnTo == NormalReturnTo then
		ShowOverlayEvent.overlay_name = name
		ShowOverlayEvent.on_done, ShowOverlayEvent.params = on_done, params

		Runtime:dispatchEvent(ShowOverlayEvent)

		ShowOverlayEvent.params = nil
	else
		on_done(params)
	end
end

-- Coming from -> return-to map; fallback return-to --
local ComingFromReturnTo, DefReturnTo = {}, NormalReturnTo

-- Set up the return-to associations.
for what, return_to in pairs{ normal = NormalReturnTo, quick_test = QuickTestReturnTo, testing = TestingReturnTo } do
	local come_from = game_loop_config["coming_from_" .. what]

	if come_from then
		ComingFromReturnTo[come_from] = return_to
	end

	if what == game_loop_config.default_return_to then
		DefReturnTo = return_to
	end
end

local CurrentLevel

local AddThingsParams = {}

function AddThingsParams:__index (k)
	return AddThingsParams[k] or (CurrentLevel and CurrentLevel[k])
end

--- DOCME
function AddThingsParams:GetPubSubList ()
	return self.m_pubsub
end

local LoadingTimer

local function ErrorFunc (err, coro)
		error(err .. "\n" .. traceback(coro, "\n(error loading level)\n", 2), 0)
end

local function NotLoading ()
	return not LoadingTimer or timers.HasExpired(LoadingTimer)
end

--- Loads a level.
--
-- The level information is gathered into a table and the **enter\_level** event list is
-- dispatched with said table as argument. It has the following fields:
--
-- * **ncols**, **nrows**: Columns wide and rows tall of level, respectively.
-- * **w**, **h**: Tile width and height, respectively.
-- * **game\_group**, **hud\_group**: Primary display groups.
-- * **bg\_layer**, **tiles\_layer**, **decals\_layer**, **things\_layer**, **markers\_layer**:
-- Game group sublayers.
--
-- After tiles and game objects have been added to the level, the **things\_loaded** event
-- list is dispatched, with the same argument. Shortly after that, a **ready\_to\_draw**
-- event is dispatched, followed by any overlay. Finally, a **ready\_to\_go** event follows.
-- @pgroup view Level scene view.
-- @param which As a **uint**, a level index as per @{game.LevelsList.GetLevel}. As a
-- **string**, a level as archived by @{solar2d_utils.persistence.Encode}.
function M.LoadLevel (view, which)
	assert(not CurrentLevel, "Level not unloaded")
	assert(NotLoading(), "Load already in progress")

	ReturnTo = ComingFromReturnTo[composer.getSceneName("previous")] or DefReturnTo
	LoadingTimer = timers.Wrap(10, function()
		-- Get the level info, either by decoding a database blob or grabbing it from the list.
		local level

		if type(which) == "string" then
			level, which = persistence.Decode(which), ""

			Call(game_loop_config.on_decode, level)
		else
			level = game_loop_config.level_list.GetLevel(which)
		end

		-- Do some preparation before entering.
		CurrentLevel = { which = which }

		Call(game_loop_config.before_entering, view, CurrentLevel, level, game_loop_config.level_list)

		local psl = pubsub.New()
		local atp = setmetatable({
			m_pubsub = psl
		}, AddThingsParams)

		-- Dispatch to "enter level" observers, now that the basics are in place.
	--	bind.Reset("loading_level")
		CurrentLevel.name = "enter_level"
		CurrentLevel.level = level
		CurrentLevel.params = atp

		Runtime:dispatchEvent(CurrentLevel)

		CurrentLevel.level, CurrentLevel.params = nil

		-- Add things to the level.
		Call(game_loop_config.add_things, CurrentLevel, level, atp)

		-- Patch up deferred objects.
	--	bind.Resolve("loading_level")
		psl:Dispatch()

		-- Dispatch to "things_loaded" observers, now that most objects are in place.
		CurrentLevel.name = "things_loaded"

		Runtime:dispatchEvent(CurrentLevel)

		-- Some of the loading might have been expensive. This can lead to unnatural starts,
		-- since the elapsed time will leak into objects' update logic. We try to account for
		-- this by waiting a frame to get a fresh start. If we show a "starting the level"
		-- overlay, it will have to do these yields anyhow, so the two situations dovetail.
		-- TODO: update these comments a bit to account for new loading logic
		local is_done = false

		DoOverlay(game_loop_config.start_overlay, function()
			is_done = true
		end)

		yield()

		CurrentLevel.name = "ready_to_draw"

		Runtime:dispatchEvent(CurrentLevel)

		while not is_done do
			yield()
		end

		-- We now have a valid level.
		CurrentLevel.name = "ready_to_go"

		Runtime:dispatchEvent(CurrentLevel)

		CurrentLevel.is_loaded, LoadingTimer = true
	end, ErrorFunc)
end

local function Leave (info)
	Runtime:dispatchEvent{ name = "leave_level", why = info.why }

	--
	local return_to = ReturnTo

	if type(return_to) == "function" then
		return_to = return_to(info)
	end

	timer.performWithDelay(game_loop_config.wait_to_end, function()
		composer.gotoScene(return_to, game_loop_config.leave_effect)
	end)
end

-- Possible overlays to play on unload --
local Overlay = { won = game_loop_config.win_overlay, lost = game_loop_config.lost_overlay }

--- Unloads the current level and returns to a menu.
--
-- This will be the appropriate game or editor menu, depending on how the level was launched.
--
-- The **leave_level** event list is dispatched, with _why_ as argument.
-- @string why Reason for unloading, which should be **won"**, **"lost"**, or **"quit"**.
function M.UnloadLevel (why)
	assert(NotLoading(), "Cannot unload: load in progress")
	assert(CurrentLevel, "No level to unload")

	if CurrentLevel.is_loaded then
		CurrentLevel.is_loaded = false

		Runtime:dispatchEvent{ name = "level_done", why = why }

		DoOverlay(Overlay[why], Leave, { which = CurrentLevel.which, why = why })
	end
end

-- Perform any other initialization.
Call(game_loop_config.on_init)

Runtime:addEventListener("unloaded", function()
	if CurrentLevel then
		Call(game_loop_config.cleanup, CurrentLevel)
	end

	CurrentLevel = nil
end)

return M