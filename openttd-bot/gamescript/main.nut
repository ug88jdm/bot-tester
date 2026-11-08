/*
 * ChatBot Game Script.
 *
 * Protocol (JSON over the admin port, see bridge/ottd_bot/gslink.py):
 *   bridge -> GS : {"id": 7, "cmd": "build_rail_line", "args": {...}}
 *   GS -> bridge : {"id": 7, "type": "progress", "msg": "..."}       (zero or more)
 *                  {"id": 7, "type": "result", "ok": true, "data": {...}}
 *                  {"id": 7, "type": "result", "ok": false, "error": "..."}
 *   GS -> bridge : {"type": "hello", "version": 1}                   (on start)
 */

require("lib/util.nut");
require("lib/heap.nut");
require("lib/pathfinder.nut");
require("lib/rail.nut");
require("lib/road.nut");
require("lib/commands.nut");

g_jobs <- [];
g_routes <- [];
g_next_route <- 1;
g_busy <- false;

function Progress(job, msg) {
	GSLog.Info(msg);
	if (job != null) GSAdmin.Send({ id = job.id, type = "progress", msg = msg });
}

function Reply(job, res) {
	res.id <- job.id;
	res.type <- "result";
	if (!GSAdmin.Send(res)) {
		GSLog.Error("Reply for job " + job.id + " could not be encoded");
		GSAdmin.Send({ id = job.id, type = "result", ok = false, error = "reply could not be encoded" });
	}
}

function RunJob(job, handler) {
	local res = null;
	try {
		res = handler(job);
	} catch (e) {
		GSLog.Error("Job " + job.cmd + " failed: " + e);
		res = { ok = false, error = "Script error: " + e };
	}
	if (res == null) res = { ok = false, error = "No result" };
	Reply(job, res);
}

function HandleMessage(data) {
	if (typeof data != "table" || !("cmd" in data)) return;
	local job = {
		id = ("id" in data) ? data.id : 0,
		cmd = data.cmd,
		args = (("args" in data) && typeof data.args == "table") ? data.args : {}
	};
	if (job.cmd in QUICK_COMMANDS) {
		RunJob(job, QUICK_COMMANDS[job.cmd]);
	} else if (job.cmd in JOB_COMMANDS) {
		g_jobs.append(job);
		local ahead = g_jobs.len() - 1 + (g_busy ? 1 : 0);
		if (ahead > 0) Progress(job, "Queued; " + ahead + " build job(s) ahead of this one.");
	} else {
		Reply(job, { ok = false, error = "Unknown command '" + job.cmd + "'" });
	}
}

/* Drain the event queue. Called from the main loop and periodically from pathfinders. */
function PumpEvents() {
	while (GSEventController.IsEventWaiting()) {
		local ev = GSEventController.GetNextEvent();
		if (ev == null) break;
		if (ev.GetEventType() == GSEvent.ET_ADMIN_PORT) {
			HandleMessage(GSEventAdminPort.Convert(ev).GetObject());
		}
	}
}

class ChatBot extends GSController {
	function Start() {
		GSLog.Info("ChatBot game script started");
		GSAdmin.Send({ type = "hello", version = 1 });
		while (true) {
			PumpEvents();
			if (g_jobs.len() > 0) {
				local job = g_jobs.remove(0);
				::g_busy = true;
				RunJob(job, JOB_COMMANDS[job.cmd]);
				::g_busy = false;
			} else {
				this.Sleep(5);
			}
		}
	}

	function Save() {
		return { routes = g_routes, next_route = g_next_route };
	}

	function Load(version, data) {
		if ("routes" in data) ::g_routes = data.routes;
		if ("next_route" in data) ::g_next_route = data.next_route;
	}
}
