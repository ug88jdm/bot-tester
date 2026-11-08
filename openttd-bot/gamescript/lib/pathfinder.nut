/*
 * A* pathfinders for rail and road.
 *
 * Both validate each step with a test-mode build command, so slopes, foundations,
 * level crossings, town authority refusals etc. are handled by the game itself.
 * Obstacles (water, rivers, other tracks, houses) can be crossed with a bridge.
 *
 * A found path is { tiles = [...], bridge_end = [...] } where bridge_end[i] is true
 * when tiles[i] is the far head of a bridge that starts at tiles[i-1].
 */

const PF_PUMP_EVERY = 250;

/* -------------------------------------------------------------------------- */
/* Rail                                                                        */
/* -------------------------------------------------------------------------- */

/*
 * Nodes are (tile, direction of travel into the tile). The track piece on a tile is
 * fixed by (previous tile, tile, next tile). Two consecutive curve pieces bending the
 * same way would form a 90 degree turn, which trains cannot take by default, so the
 * search forbids them; alternating curves make a diagonal line, which is fine.
 */
class RailPathfinder {
	company = null;
	src_end = null; src_exit = null;   // last platform tile and the tile in front of it
	dst_end = null; dst_exit = null;
	reserved = null;                    // table of tiles that must not be used
	max_iter = 0;
	max_bridge = 0;
	job = null;

	tiles = null; parents = null; dirs = null; turns = null; g = null; bend = null;
	heap = null;
	closed = null;
	off = null;

	constructor(ctx) {
		this.company = ctx.company;
		this.src_end = ctx.src_end; this.src_exit = ctx.src_exit;
		this.dst_end = ctx.dst_end; this.dst_exit = ctx.dst_exit;
		this.reserved = ctx.reserved;
		this.max_iter = ctx.max_iter;
		this.max_bridge = ctx.max_bridge;
		this.job = ctx.job;
		this.tiles = []; this.parents = []; this.dirs = []; this.turns = []; this.g = []; this.bend = [];
		this.heap = BinaryHeap();
		this.closed = {};
		this.off = DirOffsets();
	}

	function _Push(tile, parent, dir, turn, cost, is_bridge_end) {
		local idx = this.tiles.len();
		this.tiles.append(tile); this.parents.append(parent); this.dirs.append(dir);
		this.turns.append(turn); this.g.append(cost); this.bend.append(is_bridge_end);
		local h = GSMap.DistanceManhattan(tile, this.dst_exit) * 130;  // mildly greedy A*
		this.heap.Push(cost + h, idx);
	}

	function _Passable(t) {
		if (t in this.reserved) return false;
		if (GSTile.IsBuildable(t)) return true;
		if (GSRoad.IsRoadTile(t) && !GSRoad.IsRoadStationTile(t) && !GSRoad.IsRoadDepotTile(t) && !GSTile.IsStationTile(t)) return true;
		if (GSRail.IsRailTile(t) && !GSTile.IsStationTile(t) && GSTile.GetOwner(t) == this.company) return true;
		return false;
	}

	function _StepCost(t, turn) {
		local c = 100;
		if (turn != 0) c += 40;
		if (GSTile.GetSlope(t) != GSTile.SLOPE_FLAT) c += 60;
		if (GSRoad.IsRoadTile(t)) c += 250;
		if (GSRail.IsRailTile(t)) c += 400;
		return c;
	}

	function _TryBridge(idx) {
		local cur = this.tiles[idx];
		local d = this.dirs[idx];
		for (local len = 2; len <= this.max_bridge; len++) {
			local end = cur + this.off[d] * len;
			if (!OnMapInterior(end)) return;
			if (end in this.reserved) return;
			if (end == this.dst_end || end == this.src_end) return;
			if (!GSTile.IsBuildable(end)) continue;
			local bridge = PickBridge(cur, end);
			if (bridge == null) continue;
			if (TestBridge(GSVehicle.VT_RAIL, bridge, cur, end)) {
				this._Push(end, idx, d, 0, this.g[idx] + 150 * len + 500, true);
				return;
			}
		}
	}

	function Find() {
		this._Push(this.src_exit, -1, DirBetween(this.src_end, this.src_exit), 0, 0, false);
		local iter = 0;
		while (!this.heap.IsEmpty()) {
			local idx = this.heap.Pop();
			local cur = this.tiles[idx];
			local d = this.dirs[idx];
			local key = cur * 4 + d;
			if (key in this.closed) continue;
			this.closed[key] <- true;

			iter++;
			if (iter > this.max_iter) return null;
			if (iter % PF_PUMP_EVERY == 0) PumpEvents();
			if (iter % 10000 == 0) Progress(this.job, "Still searching for a track route (" + iter + " tiles explored)...");

			local prev = (this.parents[idx] == -1) ? this.src_end : this.tiles[this.parents[idx]];
			local is_bend = this.bend[idx];
			if (is_bend) prev = cur - this.off[d];

			foreach (nd in [d, (d + 1) % 4, (d + 3) % 4]) {
				if (is_bend && nd != d) continue;
				local turn = TurnSign(d, nd);
				if (turn != 0 && turn == this.turns[idx]) continue;
				local nxt = cur + this.off[nd];
				if (!OnMapInterior(nxt)) continue;

				if (nxt == this.dst_end) {
					if (cur != this.dst_exit) continue;
					if (!is_bend && !TestRail(prev, cur, nxt)) continue;
					return this._Reconstruct(idx);
				}
				if (!this._Passable(nxt)) {
					if (nd == d && !is_bend) this._TryBridge(idx);
					continue;
				}
				if (!is_bend && !TestRail(prev, cur, nxt)) continue;
				this._Push(nxt, idx, nd, turn, this.g[idx] + this._StepCost(nxt, turn), false);
				/* Also consider bridging over roads/rails instead of crossing them. */
				if (nd == d && !is_bend && !GSTile.IsBuildable(nxt)) this._TryBridge(idx);
			}
		}
		return null;
	}

	function _Reconstruct(idx) {
		local tiles = [this.dst_end];
		local bend = [false];
		while (idx != -1) {
			tiles.append(this.tiles[idx]);
			bend.append(this.bend[idx]);
			idx = this.parents[idx];
		}
		tiles.append(this.src_end);
		bend.append(false);
		tiles.reverse();
		bend.reverse();
		return { tiles = tiles, bridge_end = bend };
	}
}

/* -------------------------------------------------------------------------- */
/* Road                                                                        */
/* -------------------------------------------------------------------------- */

class RoadPathfinder {
	src_stop = null; src_front = null;
	dst_stop = null; dst_front = null;
	reserved = null;
	max_iter = 0;
	max_bridge = 0;
	job = null;

	tiles = null; parents = null; g = null; bend = null;
	heap = null;
	closed = null;
	off = null;

	constructor(ctx) {
		this.src_stop = ctx.src_stop; this.src_front = ctx.src_front;
		this.dst_stop = ctx.dst_stop; this.dst_front = ctx.dst_front;
		this.reserved = ctx.reserved;
		this.max_iter = ctx.max_iter;
		this.max_bridge = ctx.max_bridge;
		this.job = ctx.job;
		this.tiles = []; this.parents = []; this.g = []; this.bend = [];
		this.heap = BinaryHeap();
		this.closed = {};
		this.off = DirOffsets();
	}

	function _Push(tile, parent, cost, is_bridge_end) {
		local idx = this.tiles.len();
		this.tiles.append(tile); this.parents.append(parent); this.g.append(cost); this.bend.append(is_bridge_end);
		this.heap.Push(cost + GSMap.DistanceManhattan(tile, this.dst_front) * 120, idx);
	}

	function _Passable(t) {
		if (t in this.reserved) return false;
		if (GSTile.IsBuildable(t)) return true;
		if (GSTile.IsStationTile(t)) return false;
		if (GSRoad.IsRoadTile(t) && !GSRoad.IsRoadDepotTile(t)) return true;
		if (GSRail.IsRailTile(t)) return true;   // level crossing; the test build decides
		return false;
	}

	function _TryBridge(idx, d) {
		local cur = this.tiles[idx];
		for (local len = 2; len <= this.max_bridge; len++) {
			local end = cur + this.off[d] * len;
			if (!OnMapInterior(end)) return;
			if (end in this.reserved) return;
			if (!GSTile.IsBuildable(end)) continue;
			local bridge = PickBridge(cur, end);
			if (bridge == null) continue;
			if (TestBridge(GSVehicle.VT_ROAD, bridge, cur, end)) {
				this._Push(end, idx, this.g[idx] + 150 * len + 500, true);
				return;
			}
		}
	}

	function Find() {
		this._Push(this.src_front, -1, 0, false);
		local iter = 0;
		while (!this.heap.IsEmpty()) {
			local idx = this.heap.Pop();
			local cur = this.tiles[idx];
			if (cur in this.closed) continue;
			this.closed[cur] <- true;

			iter++;
			if (iter > this.max_iter) return null;
			if (iter % PF_PUMP_EVERY == 0) PumpEvents();
			if (iter % 10000 == 0) Progress(this.job, "Still searching for a road route (" + iter + " tiles explored)...");

			if (cur == this.dst_front) return this._Reconstruct(idx);

			local prev = (this.parents[idx] == -1) ? this.src_stop : this.tiles[this.parents[idx]];
			local is_bend = this.bend[idx];
			/* For a bridge end the parent is the far bridge head, so derive the axis. */
			local unit = (cur - prev) / GSMap.DistanceManhattan(cur, prev);
			local d_in = DirBetween(cur - unit, cur);

			for (local nd = 0; nd < 4; nd++) {
				if (d_in != -1 && TurnSign(d_in, nd) == 99) continue;
				if (is_bend && nd != d_in) continue;
				local nxt = cur + this.off[nd];
				if (!OnMapInterior(nxt)) continue;
				if (nxt in this.closed) continue;
				if (!this._Passable(nxt)) {
					if (!is_bend && d_in == nd && cur != this.src_front) this._TryBridge(idx, nd);
					continue;
				}
				local c;
				if (GSRoad.AreRoadTilesConnected(cur, nxt)) {
					c = 40;
				} else if (TestRoad(cur, nxt)) {
					c = 100;
					if (GSTile.GetSlope(nxt) != GSTile.SLOPE_FLAT) c += 60;
				} else {
					continue;
				}
				if (GSRail.IsRailTile(nxt)) c += 300;
				this._Push(nxt, idx, this.g[idx] + c, false);
			}
		}
		return null;
	}

	function _Reconstruct(idx) {
		local tiles = [];
		local bend = [];
		while (idx != -1) {
			tiles.append(this.tiles[idx]);
			bend.append(this.bend[idx]);
			idx = this.parents[idx];
		}
		tiles.reverse();
		bend.reverse();
		return { tiles = tiles, bridge_end = bend };
	}
}
