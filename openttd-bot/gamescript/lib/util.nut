/* Small helpers shared by the rest of the script. */

function Abs(x) { return x < 0 ? -x : x; }

function TileStr(t) {
	return "(" + GSMap.GetTileX(t) + "," + GSMap.GetTileY(t) + ")";
}

function TileXY(t) {
	return { x = GSMap.GetTileX(t), y = GSMap.GetTileY(t) };
}

/* Offsets for the four tile directions: +x, +y, -x, -y. */
function DirOffsets() {
	local sx = GSMap.GetMapSizeX();
	return [1, sx, -1, -sx];
}

/* Direction index (0..3) of the step a -> b for adjacent tiles, or -1. */
function DirBetween(a, b) {
	local off = DirOffsets();
	for (local i = 0; i < 4; i++) {
		if (a + off[i] == b) return i;
	}
	return -1;
}

/* 0 = straight, +1 / -1 = turn left/right, 99 = reversing. */
function TurnSign(a, b) {
	if (a == b) return 0;
	if (b == (a + 1) % 4) return 1;
	if (b == (a + 3) % 4) return -1;
	return 99;
}

/* True if the tile is inside the map with a one-tile margin (avoids edge wrap). */
function OnMapInterior(t) {
	if (!GSMap.IsValidTile(t)) return false;
	local x = GSMap.GetTileX(t);
	local y = GSMap.GetTileY(t);
	return x > 1 && y > 1 && x < GSMap.GetMapSizeX() - 2 && y < GSMap.GetMapSizeY() - 2;
}

function Contains(hay, needle) {
	if (hay == null) return false;
	return hay.tolower().find(needle.tolower()) != null;
}

function LastError() {
	return GSError.GetLastErrorString();
}

function AlreadyBuilt() {
	return GSError.GetLastError() == GSError.ERR_ALREADY_BUILT;
}

/* Sort helper for arrays of [score, ...] candidates. */
function CompareFirst(a, b) {
	if (a[0] < b[0]) return -1;
	if (a[0] > b[0]) return 1;
	return 0;
}

/* --- Test-mode probes. Each helper owns its GSTestMode, which is released
 * (restoring execution mode) when the function returns. --- */

function TestRail(from, tile, to) {
	local tm = GSTestMode();
	if (GSRail.BuildRail(from, tile, to)) return true;
	return AlreadyBuilt();
}

function TestRoad(a, b) {
	local tm = GSTestMode();
	if (GSRoad.BuildRoad(a, b)) return true;
	return AlreadyBuilt();
}

function TestBridge(vtype, bridge, a, b) {
	local tm = GSTestMode();
	return GSBridge.BuildBridge(vtype, bridge, a, b);
}

function TestRailStation(tile, track, len) {
	local tm = GSTestMode();
	return GSRail.BuildRailStation(tile, track, 1, len, GSBaseStation.STATION_NEW);
}

function TestTruckStop(tile, front) {
	local tm = GSTestMode();
	return GSRoad.BuildRoadStation(tile, front, GSRoad.ROADVEHTYPE_TRUCK, GSBaseStation.STATION_NEW);
}

/* Fastest bridge type that fits a span between two tiles, or null. */
function PickBridge(a, b) {
	local list = GSBridgeList_Length(GSMap.DistanceManhattan(a, b) + 1);
	if (list.IsEmpty()) return null;
	list.Valuate(GSBridge.GetMaxSpeed);
	list.Sort(GSList.SORT_BY_VALUE, GSList.SORT_DESCENDING);
	return list.Begin();
}

/* Undo everything recorded in a build log, newest first. */
function Rollback(built) {
	for (local i = built.len() - 1; i >= 0; i--) {
		local b = built[i];
		switch (b.k) {
			case "rail":   GSRail.RemoveRail(b.a, b.b, b.c); break;
			case "road":   GSRoad.RemoveRoad(b.a, b.b); break;
			case "bridge": GSBridge.RemoveBridge(b.t); break;
			case "tile":   GSTile.DemolishTile(b.t); break;
			case "veh":    GSVehicle.SellVehicle(b.v); break;
		}
	}
}

/* Make sure the current company can pay `cost`, raising the loan if allowed. */
function EnsureMoney(cost, allow_loan) {
	local bal = GSCompany.GetBankBalance(GSCompany.COMPANY_SELF);
	if (bal >= cost) return true;
	if (!allow_loan) return false;
	local want = GSCompany.GetLoanAmount() + (cost - bal);
	local interval = GSCompany.GetLoanInterval();
	if (interval > 0) want = ((want + interval - 1) / interval) * interval;
	if (want > GSCompany.GetMaxLoanAmount()) want = GSCompany.GetMaxLoanAmount();
	GSCompany.SetMinimumLoanAmount(want);
	return GSCompany.GetBankBalance(GSCompany.COMPANY_SELF) >= cost;
}

function CargoLabel(c) {
	return GSCargo.GetCargoLabel(c);
}

/* Resolve a cargo given as id or as label/name ("COAL", "coal"). */
function ResolveCargo(spec) {
	if (spec == null) return null;
	if (typeof spec == "integer") return GSCargo.IsValidCargo(spec) ? spec : null;
	local s = spec.tolower();
	foreach (c, _ in GSCargoList()) {
		if (GSCargo.GetCargoLabel(c).tolower() == s) return c;
	}
	foreach (c, _ in GSCargoList()) {
		local name = GSCargo.GetName(c);
		if (name != null && name.tolower() == s) return c;
	}
	foreach (c, _ in GSCargoList()) {
		if (Contains(GSCargo.GetName(c), s)) return c;
	}
	return null;
}

/* Cargo the source produces and the destination accepts. */
function CommonCargo(src_ind, dst_ind, wanted) {
	local produced = GSIndustryType.GetProducedCargo(GSIndustry.GetIndustryType(src_ind));
	local accepted = GSIndustryType.GetAcceptedCargo(GSIndustry.GetIndustryType(dst_ind));
	if (wanted != null) {
		if (!produced.HasItem(wanted)) return { error = GSIndustry.GetName(src_ind) + " does not produce " + CargoLabel(wanted) };
		if (!accepted.HasItem(wanted)) return { error = GSIndustry.GetName(dst_ind) + " does not accept " + CargoLabel(wanted) };
		return { cargo = wanted };
	}
	foreach (c, _ in produced) {
		if (accepted.HasItem(c)) return { cargo = c };
	}
	return { error = "No cargo produced by " + GSIndustry.GetName(src_ind) + " is accepted by " + GSIndustry.GetName(dst_ind) };
}
