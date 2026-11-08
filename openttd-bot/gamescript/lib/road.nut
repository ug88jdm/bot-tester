/*
 * Truck route: a bay truck stop at each industry, a road between them (reusing
 * existing roads where possible), a road depot and N trucks.
 */

/* Choose road type and truck model for a cargo. */
function PickTruck(cargo) {
	local best = null;
	local best_score = -1;
	foreach (rt, _ in GSRoadTypeList(GSRoad.ROADTRAMTYPES_ROAD)) {
		if (!GSRoad.IsRoadTypeAvailable(rt)) continue;
		foreach (e, _ in GSEngineList(GSVehicle.VT_ROAD)) {
			if (!GSEngine.IsBuildable(e)) continue;
			if (GSEngine.IsArticulated(e)) continue;   // articulated trucks cannot use bay stops
			if (!GSRoad.RoadVehHasPowerOnRoad(GSEngine.GetRoadType(e), rt)) continue;
			local native = GSEngine.GetCargoType(e) == cargo;
			if (!native && !GSEngine.CanRefitCargo(e, cargo)) continue;
			local score = GSEngine.GetCapacity(e) * GSEngine.GetMaxSpeed(e) + (native ? 1 : 0);
			if (score > best_score) {
				best_score = score;
				best = { rt = rt, engine = e };
			}
		}
	}
	return best;
}

function PlanTruckStop(industry, cargo, is_source, toward, avoid) {
	local radius = GSStation.GetCoverageRadius(GSStation.STATION_TRUCK_STOP);
	local list = is_source ? GSTileList_IndustryProducing(industry, radius)
	                       : GSTileList_IndustryAccepting(industry, radius);
	local off = DirOffsets();
	local cands = [];
	foreach (t, _ in list) {
		if (!GSTile.IsBuildable(t) || (t in avoid)) continue;
		for (local d = 0; d < 4; d++) {
			local front = t + off[d];
			cands.append([GSMap.DistanceManhattan(front, toward), t, front]);
		}
	}
	cands.sort(CompareFirst);
	local tested = 0;
	foreach (c in cands) {
		if (tested >= 400) break;
		local t = c[1], front = c[2];
		if (!OnMapInterior(front) || (front in avoid)) continue;
		local front_ok = GSTile.IsBuildable(front) ||
			(GSRoad.IsRoadTile(front) && !GSRoad.IsRoadStationTile(front) && !GSRoad.IsRoadDepotTile(front));
		if (!front_ok) continue;
		if (!is_source && GSTile.GetCargoAcceptance(t, cargo, 1, 1, radius) < 8) continue;
		tested++;
		if (!TestTruckStop(t, front)) continue;
		return { tile = t, front = front };
	}
	return null;
}

/* Build (or price) a road path. Bridges go first because road pieces on a tile block a bridge head. */
function BuildRoadPath(path, built, test) {
	local tm = test ? GSTestMode() : null;
	local t = path.tiles;
	local be = path.bridge_end;
	for (local i = 1; i < t.len(); i++) {
		if (!be[i]) continue;
		local bridge = PickBridge(t[i - 1], t[i]);
		if (bridge != null && GSBridge.BuildBridge(GSVehicle.VT_ROAD, bridge, t[i - 1], t[i])) {
			if (!test) built.append({ k = "bridge", t = t[i - 1] });
		} else if (!test) {
			return "could not build bridge at " + TileStr(t[i - 1]) + ": " + LastError();
		}
	}
	for (local i = 0; i < t.len() - 1; i++) {
		if (be[i + 1]) continue;
		if (GSRoad.AreRoadTilesConnected(t[i], t[i + 1])) continue;
		if (GSRoad.BuildRoad(t[i], t[i + 1])) {
			if (!test) built.append({ k = "road", a = t[i], b = t[i + 1] });
		} else if (!AlreadyBuilt() && !test) {
			return "could not build road at " + TileStr(t[i + 1]) + ": " + LastError();
		}
	}
	return null;
}

function PlaceRoadDepot(path, avoid, built) {
	local t = path.tiles;
	local be = path.bridge_end;
	local off = DirOffsets();
	local on_path = {};
	foreach (x in t) on_path[x] <- true;
	for (local i = 0; i < t.len() - 1 && i < 30; i++) {
		if (be[i] || be[i + 1]) continue;
		for (local d = 0; d < 4; d++) {
			local side = t[i] + off[d];
			if ((side in avoid) || (side in on_path) || !GSTile.IsBuildable(side)) continue;
			if (!GSRoad.BuildRoadDepot(side, t[i])) continue;
			built.append({ k = "tile", t = side });
			if (GSRoad.BuildRoad(side, t[i]) || AlreadyBuilt()) {
				built.append({ k = "road", a = side, b = t[i] });
				return side;
			}
			GSTile.DemolishTile(side);
			built.pop();
		}
	}
	return null;
}

/* Buy one truck with orders (or shared orders). Returns vehicle id or error string. */
function BuildTruck(depot, engine, cargo, src_tile, dst_tile, share_with) {
	local v = GSVehicle.BuildVehicle(depot, engine);
	if (!GSVehicle.IsValidVehicle(v)) return "could not buy truck: " + LastError();
	if (GSEngine.GetCargoType(engine) != cargo && !GSVehicle.RefitVehicle(v, cargo)) {
		GSVehicle.SellVehicle(v);
		return "could not refit truck: " + LastError();
	}
	if (share_with != null && GSVehicle.IsValidVehicle(share_with)) {
		GSOrder.ShareOrders(v, share_with);
	} else {
		GSOrder.AppendOrder(v, src_tile, GSOrder.OF_FULL_LOAD_ANY | GSOrder.OF_NON_STOP_INTERMEDIATE);
		GSOrder.AppendOrder(v, dst_tile, GSOrder.OF_UNLOAD | GSOrder.OF_NO_LOAD | GSOrder.OF_NON_STOP_INTERMEDIATE);
	}
	GSVehicle.StartStopVehicle(v);
	return v;
}

function CmdBuildRoadRoute(job) {
	local a = job.args;
	local company = Arg(a, "company", null);
	if (!ValidCompany(company)) return { ok = false, error = "Invalid company" };
	local cm = GSCompanyMode(company);

	local src = Arg(a, "source", null);
	local dst = Arg(a, "dest", null);
	if (src == null || !GSIndustry.IsValidIndustry(src)) return { ok = false, error = "Unknown source industry id" };
	if (dst == null || !GSIndustry.IsValidIndustry(dst)) return { ok = false, error = "Unknown destination industry id" };
	if (src == dst) return { ok = false, error = "Source and destination are the same industry" };

	local wanted = null;
	if (Arg(a, "cargo", null) != null) {
		wanted = ResolveCargo(a.cargo);
		if (wanted == null) return { ok = false, error = "Unknown cargo '" + a.cargo + "'" };
	}
	local cc = CommonCargo(src, dst, wanted);
	if ("error" in cc) return { ok = false, error = cc.error };
	local cargo = cc.cargo;

	local trucks = Arg(a, "trucks", 3);
	if (trucks < 1) trucks = 1;
	if (trucks > 15) trucks = 15;
	local dry_run = Arg(a, "dry_run", false);
	local allow_loan = Arg(a, "allow_loan", true);
	local src_name = GSIndustry.GetName(src);
	local dst_name = GSIndustry.GetName(dst);

	local pick = PickTruck(cargo);
	if (pick == null) return { ok = false, error = "No truck model for " + CargoLabel(cargo) + " is available to your company yet" };
	GSRoad.SetCurrentRoadType(pick.rt);

	Progress(job, "Planning " + CargoLabel(cargo) + " truck route " + src_name + " -> " + dst_name + "...");
	local avoid = {};
	local s1 = PlanTruckStop(src, cargo, true, GSIndustry.GetLocation(dst), avoid);
	if (s1 == null) return { ok = false, error = "No room for a truck stop near " + src_name };
	avoid[s1.tile] <- true;
	local s2 = PlanTruckStop(dst, cargo, false, s1.front, avoid);
	if (s2 == null) return { ok = false, error = "No room for a truck stop accepting " + CargoLabel(cargo) + " near " + dst_name };
	avoid[s2.tile] <- true;

	local pf = RoadPathfinder({
		src_stop = s1.tile, src_front = s1.front,
		dst_stop = s2.tile, dst_front = s2.front,
		reserved = avoid,
		max_iter = GSController.GetSetting("max_pf_iterations"),
		max_bridge = GSController.GetSetting("max_bridge_length"),
		job = job
	});
	local path = pf.Find();
	if (path == null) return { ok = false, error = "Could not find a buildable road route between the two industries." };

	local est_acc = GSAccounting();
	TestTruckStop(s1.tile, s1.front);
	TestTruckStop(s2.tile, s2.front);
	BuildRoadPath(path, [], true);
	local est = est_acc.GetCosts();
	est += GSRoad.GetBuildCost(pick.rt, GSRoad.BT_DEPOT) + 4 * GSRoad.GetBuildCost(pick.rt, GSRoad.BT_ROAD);
	est += GSEngine.GetPrice(pick.engine) * trucks;

	local summary = {
		cargo = CargoLabel(cargo),
		source = src_name, dest = dst_name,
		road_tiles = path.tiles.len(),
		truck_model = GSEngine.GetName(pick.engine),
		trucks = trucks,
		estimated_cost = est
	};
	if (dry_run) {
		summary.dry_run <- true;
		summary.bank_balance <- GSCompany.GetBankBalance(GSCompany.COMPANY_SELF);
		summary.loan_headroom <- GSCompany.GetMaxLoanAmount() - GSCompany.GetLoanAmount();
		return { ok = true, data = summary };
	}
	if (!EnsureMoney(est * 11 / 10, allow_loan)) {
		return { ok = false, error = "Not enough money: this route needs about " + est + " but the company has " +
			GSCompany.GetBankBalance(GSCompany.COMPANY_SELF) };
	}

	local acc = GSAccounting();
	local built = [];
	Progress(job, "Building truck stops and " + path.tiles.len() + " tiles of road...");
	if (!GSRoad.BuildRoadStation(s1.tile, s1.front, GSRoad.ROADVEHTYPE_TRUCK, GSBaseStation.STATION_NEW)) return RailFail(built, "Source truck stop failed: " + LastError());
	built.append({ k = "tile", t = s1.tile });
	if (!GSRoad.BuildRoadStation(s2.tile, s2.front, GSRoad.ROADVEHTYPE_TRUCK, GSBaseStation.STATION_NEW)) return RailFail(built, "Destination truck stop failed: " + LastError());
	built.append({ k = "tile", t = s2.tile });
	foreach (s in [s1, s2]) {
		if (GSRoad.BuildRoad(s.front, s.tile)) built.append({ k = "road", a = s.front, b = s.tile });
		else if (!AlreadyBuilt()) return RailFail(built, "Could not connect truck stop: " + LastError());
	}
	local err = BuildRoadPath(path, built, false);
	if (err != null) return RailFail(built, "Road construction failed (" + err + "); everything was removed again.");

	local depot = PlaceRoadDepot(path, avoid, built);
	if (depot == null) return RailFail(built, "Could not place a road depot next to the route; everything was removed again.");

	Progress(job, "Buying " + trucks + " trucks...");
	local vehicles = [];
	for (local i = 0; i < trucks; i++) {
		local v = BuildTruck(depot, pick.engine, cargo, s1.tile, s2.tile, vehicles.len() > 0 ? vehicles[0] : null);
		if (typeof v == "string") {
			if (vehicles.len() == 0) return RailFail(built, v);
			break;
		}
		vehicles.append(v);
		GSController.Sleep(15);   // stagger departures
	}

	local route = AddRoute("road", company, src, dst, cargo, depot, pick.engine, vehicles);
	summary.route_id <- route.id;
	summary.trucks = vehicles.len();
	summary.cost <- acc.GetCosts();
	return { ok = true, data = summary };
}
