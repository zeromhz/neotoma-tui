--- Neotoma for Yazi: browse Neotoma disk catalogs, including disconnected
--- disks, as the read-only `neotoma://` filesystem.
---
--- All catalog access goes through the read-only `neotoma` command-line tool
--- (`neotoma <command> --json`). This plugin never writes a catalog or an
--- original. Connected, unchanged originals are previewed and copied directly;
--- disconnected disks still list names, sizes and dates.
---
--- URL layout (a Yazi hub: each entry's domain is its name, its list key):
---   neotoma:///@//                             all disks
---   neotoma://…/@…/<Disk · id>/<path>          a cataloged folder or file
---   neotoma://…/@…/.search/<query>             search results; each result is
---       named `<Disk · id>∕<path with ∕>` (U+2215) so it stays one entry.

local M = {}

local ROOT = "neotoma:///@//"
local SEARCH = ".search"
local SEP = "∕"
local DIR_MODE = tonumber("40555", 8)
local FILE_MODE = tonumber("100444", 8)

--- True the first time it is asked about a search, so that a cut-off is announced once and not again each time
--- the listing refreshes. Each call into the plugin starts from a fresh Lua state; this lives in Yazi's own.
local first_time = ya.sync(function(state, query)
	state.told = state.told or {}
	if state.told[query] then
		return false
	end
	state.told[query] = true
	return true
end)

local function warn(content)
	ya.notify { title = "Neotoma", content = tostring(content), timeout = 5, level = "warn" }
end

-- `neotoma` CLI ------------------------------------------------------------

local function run(job, args)
	local bin = job.opts and job.opts.bin or "neotoma"
	local output, err = Command(bin):arg("--json"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not output then
		return nil, Err("Failed to start `%s`: %s", bin, err)
	end

	local value = ya.json_decode(output.stdout)
	if type(value) ~= "table" then
		return nil, Err("Unexpected output from `%s`: %s", bin, output.stderr)
	elseif value.error then
		local missing = value.error.code == "not-found" or value.error.code == "unknown-disk"
		return nil, Error.fs { kind = missing and "NotFound" or "Other", message = value.error.message }
	end
	return value
end

-- Locations ----------------------------------------------------------------

local function unflatten(name)
	local parts = {}
	for part in (name .. SEP):gmatch("(.-)" .. SEP) do
		parts[#parts + 1] = part
	end
	return parts
end

--- @return { kind: "root"|"search-root"|"search"|"item", disk: string?, path: string?, query: string? }
local function locate(url)
	local parts = {}
	for part in tostring(url.path):gmatch("[^/]+") do
		parts[#parts + 1] = part
	end

	if #parts == 0 then
		return { kind = "root" }
	elseif parts[1] ~= SEARCH then
		return { kind = "item", disk = parts[1], path = table.concat(parts, "/", 2) }
	elseif #parts == 1 then
		return { kind = "search-root" }
	elseif #parts == 2 then
		return { kind = "search", query = (parts[2]:gsub(SEP, "/")) }
	end

	local hit = unflatten(parts[3])
	local rest = { table.unpack(hit, 2) }
	for i = 4, #parts do
		rest[#rest + 1] = parts[i]
	end
	return { kind = "item", disk = hit[1], path = table.concat(rest, "/") }
end

-- Files --------------------------------------------------------------------

local function dir_file(url, listed)
	local stat = Stat { mode = DIR_MODE, ctime = listed }
	return File { url = url, stat = stat, lstat = stat }
end

--- A number for one URL, used as a file's change time.
---
--- Yazi skips MIME detection for a file it has already examined, which it
--- decides by the backing path plus the size and times, but it stores the result
--- by URL. One original reached through a second URL (a search result after
--- browsing to the file, a file inside a folder opened from a search, the same
--- hit under two searches) would therefore never get a MIME type, and so no
--- preview. The change time is part of that signature and Yazi shows it
--- nowhere, so it carries a value derived from the URL.
local function text_time(text)
	local hash = 5381
	for i = 1, #text do
		hash = (hash * 33 + text:byte(i)) % 2147483647
	end
	return hash + 1
end

-- The path alone: the same file's URL is spelled differently when it is listed and when it is looked up.
local function url_time(url) return text_time(tostring(url.path)) end

--- What was last learned about the catalog, kept in Yazi's own state because
--- each call into the plugin starts from a fresh Lua state: the tool's `files`
--- and `revision` values, and the time until which they need not be asked for
--- again.
local recall = ya.sync(function(state)
	local r = state.catalog or {}
	return r.files, r.revision, r.rest or 0
end)

local remember = ya.sync(function(state, files, revision, rest)
	state.catalog = { files = files, revision = revision, rest = rest }
end)

--- A number for the state a folder listing was made from, kept in the folder's
--- change time.
---
--- Yazi asks every two seconds whether each open folder of a virtual
--- filesystem changed, and lists it again unless the answer is no. Listing
--- runs the `neotoma` tool, which opens the library. So the answer is worked
--- out as cheaply as it can be. `neotoma revision` gives two values: `files`,
--- three file times read without opening the library, which move on every
--- write Neotoma makes; and `revision`, the catalog's own state, which takes
--- opening the library. Handing back the `files` value last seen gets `files`
--- alone while nothing was written. One answer serves every open folder, and
--- after the library has been opened it is not asked again for six seconds, so
--- a Neotoma that writes all the time costs one opening in six seconds, not a
--- listing of every folder every two.
---
--- A folder is listed again when `revision` changes, or every half minute so
--- that a disk being connected or disconnected shows up. A `neotoma` that
--- gives no such values is not asked again for six seconds, and every folder
--- is then listed again each time.
local function listing_time(job)
	local now = ya.time().unix
	local files, revision, rest = recall()
	if now >= rest then
		local value = run(job, files and revision and { "revision", "--after", files } or { "revision" })
		if not value or not value.files then
			files, revision = nil, nil
			remember(nil, nil, now + 6)
		elseif value.revision then
			files, revision = value.files, value.revision
			remember(files, revision, now + 6)
		else
			remember(files, revision, now + 1.5)
		end
	end
	if not revision then
		return nil
	end
	return text_time(revision .. ":" .. math.floor(now / 30))
end

--- A catalog entry as a Yazi file. Unchanged connected originals become the
--- file's backing, so previews and MIME detection read the real bytes.
local function entry_file(url, e, listed)
	local stat = Stat {
		mode = e.dir and DIR_MODE or FILE_MODE,
		len = e.size,
		mtime = e.mtime,
		ctime = e.dir and listed or url_time(url),
	}
	local backing = not e.dir and e.state == "available" and e.original or nil
	return File { url = url, stat = stat, lstat = stat, backing = backing and Path.os(backing) }
end

--- The file for a URL. `listed` is the folder's `listing_time`, when the caller already has it.
local function file(job, url, listed)
	local loc = locate(url)
	if loc.kind ~= "item" or loc.path == "" then
		return dir_file(url, listed or listing_time(job))
	end

	local value, err = run(job, { "stat", loc.disk, loc.path })
	if not value then
		return nil, err
	end
	return entry_file(url, value.entry, value.entry.dir and (listed or listing_time(job)) or nil)
end

--- Nothing when the folder's listing is still current, so Yazi keeps it; the folder's file otherwise.
local function revalidate(job)
	local listed, old = listing_time(job), job.file.stat.ctime
	if listed and old and old.unix == listed then
		return nil
	end
	return file(job, job.file.url, listed)
end

local function child(url, name) return url:join(name):with_domain(name) end

local function read_dir(job)
	local loc = locate(job.url)
	if loc.kind == "search-root" then
		return
	end

	local value, err
	if loc.kind == "root" then
		value, err = run(job, { "disks" })
	elseif loc.kind == "search" then
		value, err = run(job, { "search", "--limit", "200", "--", loc.query })
	else
		value, err = run(job, { "ls", "--", loc.disk, loc.path ~= "" and loc.path or "/" })
	end
	if not value then
		return nil, err
	end

	if loc.kind == "root" then
		for _, disk in ipairs(value.disks) do
			coroutine.yield(dir_file(child(job.url, disk.folder)))
		end
	elseif loc.kind == "search" then
		if value.total > #value.hits and first_time(loc.query) then
			warn(string.format("Showing %d of %d matches for “%s”. Narrow the search to see the rest.", #value.hits, value.total, loc.query))
		end
		for _, hit in ipairs(value.hits) do
			local name = hit.disk_folder .. SEP .. hit.path:gsub("/", SEP)
			coroutine.yield(entry_file(child(job.url, name), hit))
		end
	else
		for _, entry in ipairs(value.entries) do
			coroutine.yield(entry_file(child(job.url, entry.name), entry))
		end
	end
end

local function copy_to(job)
	local loc = locate(job.from)
	if loc.kind ~= "item" or loc.path == "" then
		return nil, Err("Only cataloged files can be copied from Neotoma")
	elseif not job.to.spec.is_regular then
		return nil, Error.fs { kind = "CrossesDevices", message = "Neotoma copies only to local folders" }
	end

	local value, err = run(job, { "original", "--", loc.disk, loc.path })
	if not value then
		return nil, err
	end

	local original = value.original
	if original.state == "offline" then
		return nil, Err("“%s” is on a disconnected disk", original.name)
	elseif original.state ~= "available" then
		return nil, Err("“%s” changed since Neotoma cataloged it; rescan it in Neotoma first", original.name)
	end

	local n, err = fs.copy(Url(original.original), job.to)
	if not n then
		return nil, err
	end
	coroutine.yield(n)
end

-- Plugin entry points ------------------------------------------------------

--- `plugin neotoma` opens the disk list; `plugin neotoma search` prompts for a
--- catalog search across all disks.
function M:entry(job)
	if job.args[1] ~= "search" then
		return ya.emit("cd", { Url(ROOT), raw = true })
	end

	local query, event = ya.input { title = "Search Neotoma:", pos = { "top-center", y = 3, w = 50 } }
	if event ~= 1 or query == "" then
		return
	end
	ya.emit("cd", { child(child(Url(ROOT), SEARCH), (query:gsub("/", SEP))), raw = true })
end

function M:provide(job)
	local op = job.op
	if op == "Capabilities" then
		-- stylua: ignore
		return {
			absolute = 1, canonicalize = 1, casefold = 1, metadata = 1, symlink_metadata = 1,
			file = 1, read_dir = 1, revalidate = 1, copy_to = 1,
		}
	elseif op == "Absolute" or op == "Canonicalize" then
		return fs.clean_url(job.url)
	elseif op == "Casefold" then
		return job.url
	elseif op == "Metadata" or op == "SymlinkMetadata" then
		local f, err = file(job, job.url)
		return f and f.stat, err
	elseif op == "File" then
		return file(job, job.url)
	elseif op == "Revalidate" then
		return revalidate(job)
	elseif op == "ReadDir" then
		return ya.co(function() return read_dir(job) end)
	elseif op == "CopyTo" then
		return ya.co(function() return copy_to(job) end)
	end

	return false, Error.fs { kind = "Unsupported", message = "Neotoma disks are read-only (" .. op .. ")" }
end

--- MIME fetcher: real detection for connected originals, `neotoma/offline` otherwise.
function M:fetch(job)
	return ya.co(function()
		local updates, present = {}, {}
		for _, f in ipairs(job.files) do
			if fs.stat(Url(tostring(f.path))) then
				present[#present + 1] = f
			else
				updates[f.url] = coroutine.yield(f, { "neotoma/offline" }) and "neotoma/offline" or nil
			end
		end

		require("mime.dir").commit(updates)
		if #present == 0 then
			return
		end

		local next = require("mime.local"):fetch(ya.dict_merge(job, { files = present }))
		local file, result = next()
		while file do
			file, result = next(coroutine.yield(file, result))
		end
	end)
end

--- Previewer for `neotoma/offline`.
function M:peek(job)
	local f = job.file
	local lines = {
		ui.Line("Original not available on this Mac"):style(ui.Style():fg("yellow")),
		"",
		"The disk is disconnected, or the file changed since Neotoma cataloged it.",
		"",
		"Size:      " .. ya.readable_size(f.stat.len or 0),
		"Modified:  " .. (f.stat.mtime and tostring(f.stat.mtime) or "-"),
	}
	ya.preview_widget(job, ui.Text(lines):area(job.area):wrap(ui.Wrap.YES))
end

function M:seek() end

return M
