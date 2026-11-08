/*
 * Point-to-point rail line: terminus station at each industry, single track,
 * a depot near the source and one full-load train.
 */

/* Best wagon on a rail type for a cargo, or null. */
function BestWagon(rt, cargo) {
	local best = null;
	local best_score = -1;
	foreach (e, _ in GSEngineList(GSVehicle.VT_RAIL)) {
		if (!GSEngine.IsBuildable(e) || !GSEngine.IsWagon(e)) continue;
		if (!GSEngine.CanRunOnRail(e, rt)) continue;
		local native = GSEngine.GetCargoType(e) == cargo;
		if (!native && !GSEngine.CanRefitCargo(e, cargo)) continue;
		local score = GSEngine.GetCapacity(e) + (native ? 1000 : 0);
		if (score > best_score) { best = e; best_score = score; }
	}
	return best;
}

/* Choose rail type, locomotive and wagon for a cargo. */
function PickRailEngines(cargo) {
	local best = null;
	local best_score = -1;
	foreach (rt, _ in GSRailTypeList()) {
		if (!GSRail.IsRailTypeAvailable(rt)) continue;
		local wagon = BestWagon(rt, cargo);
		if (wagon == null) continue;
		foreach (e, _ in GSEngineList(GSVehicle.VT_RAIL)) {
			if (!GSEngine.IsBuildable(e) || GSEngine.IsWagon(e)) continue;
			if (!GSEngine.CanRunOnRail(e, rt) || !GSEngine.HasPowerOnRail(e, rt)) continue;
			if (GSEngine.GetCapacity(e) > 0) continue;  // skip passenger/mail multiple units
			local speed = GSEngine.GetMaxSpeed(e);
			if (speed > 250) speed = 250;
			local score = GSEngine.GetPower(e) * speed / 100 + GSEngine.GetReliability(e);
			if (score > best_score) {
				best_score = score;
				best = { rt = rt, loco = e, wagon = wagon };
			}
		}
	}
	return best;
}

/*
 * Find a spot for a terminus station of `len` tiles serving an industry.
 * The open end faces `toward`. `avoid` holds tiles that must stay free.
 */
function PlanRailStation(industry, cargo, is_source, toward, len, avoid) {
	local radius = GSStation.GetCoverageRadius(GSStation.STATION_TRAIN);
	local list = is_source ? GSTileList_IndustryProducing(industry, radius)
	                       : GSTileList_IndustryAccepting(industry, radius);
	local sx = GSMap.GetMapSizeX();
	local cands = [];
	foreach (t, _ in list) {
		for (local axis = 0; axis < 2; axis++) {
			local step = (axis == 0) ? 1 : sx;
			local low_exit = t - step;
			local high_end = t + (len - 1) * step;
			local high_exit = t + len * step;
			local dl = GSMap.DistanceManhattan(low_exit, toward);
			local dh = GSMap.DistanceManhattan(high_exit, toward);
			if (dl <= dh) cands.append([dl, t, axis, t, low_exit, step]);
			else cands.append([dh, t, axis, high_end, high_exit, step]);
		}
	}
	cands.sort(CompareFirst);

	local tested = 0;
	foreach (c in cands) {
		if (tested >= 400) break;
		local t = c[1], axis = c[2], end = c[3], exit = c[4], step = c[5];
		local w = (axis == 0) ? len : 1;
		local h = (axis == 0) ? 1 : len;
		if (!OnMapInterior(exit) || !GSTile.IsBuildable(exit) || (exit in avoid)) continue;
		local tiles = [];
		local clash = false;
		for (local i = 0; i < len; i++) {
			local pt = t + i * step;
			if (pt in avoid) { clash = true; break; }
			tiles.append(pt);
		}
		if (clash) continue;
		if (!is_source && GSTile.GetCargoAcceptance(t, cargo, w, h, radius) < 8) continue;
		tested++;
		local track = (axis == 0) ? GSRail.RAILTRACK_NE_SW : GSRail.RAILTRACK_NW_SE;
		if (!TestRailStation(t, track, len)) continue;
		return { tile = t, track = track, end = end, exit = exit, tiles = tiles };
	}
	return null;
}

/* Build (or, with test = true, price) the track along a path. Returns null or an error. */
function BuildRailPath(path, built, test) {
	local tm = test ? GSTestMode() : null;
	local t = path.tiles;
	local be = path.bridge_end;
	for (local i = 1; i < t.len() - 1; i++) {
		if (be[i]) continue;                    // far bridge head: nothing to lay
		if (be[i + 1]) {                        // bridge from t[i] to t[i+1]
			local bridge = PickBridge(t[i], t[i + 1]);
			if (bridge == null || !GSBridge.BuildBridge(GSVehicle.VT_RAIL, bridge, t[i], t[i + 1])) {
				if (!test) return "could not build bridge at " + TileStr(t[i]) + ": " + LastError();
			} else if (!test) {
				built.append({ k = "bridge", t = t[i] });
			}
			continue;
		}
		if (GSRail.BuildRail(t[i - 1], t[i], t[i + 1])) {
			if (!test) built.append({ k = "rail", a = t[i - 1], b = t[i], c = t[i + 1] });
		} else if (!AlreadyBuilt() && !test) {
			return "could not lay track at " + TileStr(t[i]) + ": " + LastError();
		}
	}
	return null;
}

/* Put a depot beside a straight stretch near the source and connect it both ways. */
function PlaceRailDepot(path, avoid, built) {
	local t = path.tiles;
	local be = path.bridge_end;
	local sx = GSMap.GetMapSizeX();
	local on_path = {};
	foreach (x in t) on_path[x] <- true;
	for (local i = 2; i < t.len() - 2 && i < 40; i++) {
		if (be[i] || be[i + 1]) continue;
		if (t[i + 1] - t[i] != t[i] - t[i - 1]) continue;   // straight pieces only
		local step = t[i + 1] - t[i];
		local perp = (Abs(step) == 1) ? sx : 1;
		foreach (side in [t[i] + perp, t[i] - perp]) {
			if ((side in avoid) || (side in on_path) || !GSTile.IsBuildable(side)) continue;
			if (!GSRail.BuildRailDepot(side, t[i])) continue;
			built.append({ k = "tile", t = side });
			local linked = false;
			if (GSRail.BuildRail(side, t[i], t[i + 1])) {
				built.append({ k = "rail", a = side, b = t[i], c = t[i + 1] });
				linked = true;
			}
			if (GSRail.BuildRail(side, t[i], t[i - 1])) {
				built.append({ k = "rail", a = side, b = t[i], c = t[i - 1] });
				linked = true;
			}
			if (linked) return side;
			GSTile.DemolishTile(side);
			built.pop();
		}
	}
	return null;
}

/* Build a locomotive plus as many wagons as fit the platform. Returns vehicle id or error string. */
function BuildTrain(depot, eng, cargo, len, built) {
	local v = GSVehicle.BuildVehicle(depot, eng.loco);
	if (!GSVehicle.IsValidVehicle(v)) return "could not buy locomotive: " + LastError();
	built.append({ k = "veh", v = v });
	local max_len = len * 16;
	for (local n = 0; n < 40; n++) {
		local w = GSVehicle.BuildVehicle(depot, eng.wagon);
		if (!GSVehicle.IsValidVehicle(w)) break;
		if (GSEngine.GetCargoType(eng.wagon) != cargo && !GSVehicle.RefitVehicle(w, cargo)) {
			GSVehicle.SellVehicle(w);
			break;
		}
		if (!GSVehicle.MoveWagon(w, 0, v, GSVehicle.GetNumWagons(v) - 1)) {
			GSVehicle.SellVehicle(w);
			break;
		}
		if (GSVehicle.GetLength(v) > max_len) {
			GSVehicle.SellWagon(v, GSVehicle.GetNumWagons(v) - 1);
			break;
		}
	}
	if (GSVehicle.GetNumWagons(v) < 2) return "could not attach any wagons: " + LastError();
	return v;
}

function RailFail(built, msg) {
	Rollback(built);
	return { ok = false, error = msg };
}

function CmdBuildRailLine(job) {
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

	local len = Arg(a, "platform_length", 4);
	if (len < 2) len = 2;
	if (len > 7) len = 7;
	local dry_run = Arg(a, "dry_run", false);
	local allow_loan = Arg(a, "allow_loan", true);
	local src_name = GSIndustry.GetName(src);
	local dst_name = GSIndustry.GetName(dst);

	local eng = PickRailEngines(cargo);
	if (eng == null) return { ok = false, error = "No locomotive and " + CargoLabel(cargo) + " wagon are available to your company yet" };
	GSRail.SetCurrentRailType(eng.rt);

	Progress(job, "Planning " + CargoLabel(cargo) + " line " + src_name + " -> " + dst_name + " (" +
		GSMap.DistanceManhattan(GSIndustry.GetLocation(src), GSIndustry.GetLocation(dst)) + " tiles)...");

	local avoid = {};
	local s1 = PlanRailStation(src, cargo, true, GSIndustry.GetLocation(dst), len, avoid);
	if (s1 == null) return { ok = false, error = "No room for a " + len + "-tile station near " + src_name };
	foreach (t in s1.tiles) avoid[t] <- true;
	avoid[s1.exit] <- true;
	local s2 = PlanRailStation(dst, cargo, false, s1.exit, len, avoid);
	if (s2 == null) return { ok = false, error = "No room for a " + len + "-tile station accepting " + CargoLabel(cargo) + " near " + dst_name };
	delete avoid[s1.exit];
	foreach (t in s2.tiles) avoid[t] <- true;

	local pf = RailPathfinder({
		company = company,
		src_end = s1.end, src_exit = s1.exit,
		dst_end = s2.end, dst_exit = s2.exit,
		reserved = avoid,
		max_iter = GSController.GetSetting("max_pf_iterations"),
		max_bridge = GSController.GetSetting("max_bridge_length"),
		job = job
	});
	local path = pf.Find();
	if (path == null) return { ok = false, error = "Could not find a buildable track route between the two stations (terrain, water or buildings in the way). Try a shorter platform or a different pair." };

	/* Price everything in test mode. */
	local est_acc = GSAccounting();
	TestRailStation(s1.tile, s1.track, len);
	TestRailStation(s2.tile, s2.track, len);
	BuildRailPath(path, [], true);
	local est = est_acc.GetCosts();
	est +=GSRail.GetBuildCost(eng.rt, GSRail.BT_DEPOT) + 2 * GSRail.GetBuildCost(eng.rt, GSRail.BT_TRACK);
	local train_cost = GSEngine.GetPrice(eng.loco) + GSEngine.GetPrice(eng.wagon) * (len * 2 - 1);
	est += train_cost;

	local summary = {
		cargo = CargoLabel(cargo),
		source = src_name, dest = dst_name,
		track_tiles = path.tiles.len(),
		platform_length = len,
		locomotive = GSEngine.GetName(eng.loco),
		wagon = GSEngine.GetName(eng.wagon),
		estimated_cost = est
	};
	if (dry_run) {
		summary.dry_run <- true;
		summary.bank_balance <- GSCompany.GetBankBalance(GSCompany.COMPANY_SELF);
		summary.loan_headroom <- GSCompany.GetMaxLoanAmount() - GSCompany.GetLoanAmount();
		return { ok = true, data = summary };
	}
	if (!EnsureMoney(est * 11 / 10, allow_loan)) {
		return { ok = false, error = "Not enough money: this line needs about " + est + " but the company has " +
			GSCompany.GetBankBalance(GSCompany.COMPANY_SELF) + (allow_loan ? " even with the maximum loan" : " (loan not allowed)") };
	}

	local acc = GSAccounting();
	local built = [];
	Progress(job, "Building stations...");
	if (!GSRail.BuildRailStation(s1.tile, s1.track, 1, len, GSBaseStation.STATION_NEW)) return RailFail(built, "Source station failed: " + LastError());
	foreach (t in s1.tiles) built.append({ k = "tile", t = t });
	if (!GSRail.BuildRailStation(s2.tile, s2.track, 1, len, GSBaseStation.STATION_NEW)) return RailFail(built, "Destination station failed: " + LastError());
	foreach (t in s2.tiles) built.append({ k = "tile", t = t });

	Progress(job, "Laying " + path.tiles.len() + " tiles of track...");
	local err = BuildRailPath(path, built, false);
	if (err != null) return RailFail(built, "Track construction failed (" + err + "); everything was removed again.");

	local depot = PlaceRailDepot(path, avoid, built);
	if (depot == null) return RailFail(built, "Could not place a train depot next to the line; everything was removed again.");

	Progress(job, "Buying train...");
	local v = BuildTrain(depot, eng, cargo, len, built);
	if (typeof v == "string") return RailFail(built, v);
	GSOrder.AppendOrder(v, s1.tile, GSOrder.OF_FULL_LOAD_ANY | GSOrder.OF_NON_STOP_INTERMEDIATE);
	GSOrder.AppendOrder(v, s2.tile, GSOrder.OF_UNLOAD | GSOrder.OF_NO_LOAD | GSOrder.OF_NON_STOP_INTERMEDIATE);
	if (!GSVehicle.StartStopVehicle(v)) return RailFail(built, "Could not start the train: " + LastError());

	local route = AddRoute("rail", company, src, dst, cargo, depot, eng.loco, [v]);
	summary.route_id <- route.id;
	summary.cost <- acc.GetCosts();
	summary.wagons <- GSVehicle.GetNumWagons(v) - 1;
	summary.source_station <- TileXY(s1.tile);
	summary.dest_station <- TileXY(s2.tile);
	return { ok = true, data = summary };
}
