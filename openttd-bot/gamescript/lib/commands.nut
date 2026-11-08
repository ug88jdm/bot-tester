/* Command handlers. Each takes a job {id, cmd, args} and returns {ok, data|error}. */

function Arg(a, key, def) {
	if (a == null || !(key in a) || a[key] == null) return def;
	return a[key];
}

function ValidCompany(c) {
	if (c == null || typeof c != "integer") return false;
	return GSCompany.ResolveCompanyID(c) != GSCompany.COMPANY_INVALID;
}

/* Split a string on spaces. */
function Words(s) {
	local out = [];
	local cur = "";
	for (local i = 0; i < s.len(); i++) {
		local ch = s.slice(i, i + 1);
		if (ch == " " || ch == ",") {
			if (cur.len() > 0) out.append(cur);
			cur = "";
		} else {
			cur += ch;
		}
	}
	if (cur.len() > 0) out.append(cur);
	return out;
}

function AddRoute(kind, company, src, dst, cargo, depot, engine, vehicles) {
	local r = {
		id = g_next_route,
		kind = kind,
		company = company,
		src = src, dst = dst,
		src_name = GSIndustry.GetName(src),
		dst_name = GSIndustry.GetName(dst),
		cargo = cargo,
		depot = depot,
		engine = engine,
		vehicles = vehicles
	};
	::g_next_route++;
	g_routes.append(r);
	return r;
}

function FindRoute(id) {
	foreach (r in g_routes) if (r.id == id) return r;
	return null;
}

function IndustryInfo(i) {
	local type = GSIndustry.GetIndustryType(i);
	local loc = GSIndustry.GetLocation(i);
	local produces = [];
	foreach (c, _ in GSIndustryType.GetProducedCargo(type)) {
		produces.append({
			cargo = CargoLabel(c),
			last_month = GSIndustry.GetLastMonthProduction(i, c),
			transported_pct = GSIndustry.GetLastMonthTransportedPercentage(i, c)
		});
	}
	local accepts = [];
	foreach (c, _ in GSIndustryType.GetAcceptedCargo(type)) accepts.append(CargoLabel(c));
	return {
		id = i,
		name = GSIndustry.GetName(i),
		type = GSIndustryType.GetName(type),
		x = GSMap.GetTileX(loc),
		y = GSMap.GetTileY(loc),
		town = GSTown.GetName(GSTile.GetClosestTown(loc)),
		produces = produces,
		accepts = accepts
	};
}

function MatchesAllWords(text, words) {
	foreach (w in words) if (!Contains(text, w)) return false;
	return true;
}

function CmdPing(job) {
	return { ok = true, data = { version = 1, map_x = GSMap.GetMapSizeX(), map_y = GSMap.GetMapSizeY() } };
}

function CmdListIndustries(job) {
	local a = job.args;
	local words = Words(Arg(a, "query", ""));
	local cargo = null;
	if (Arg(a, "cargo", null) != null) {
		cargo = ResolveCargo(a.cargo);
		if (cargo == null) return { ok = false, error = "Unknown cargo '" + a.cargo + "'" };
	}
	local role = Arg(a, "role", "any");
	local offset = Arg(a, "offset", 0);
	local limit = Arg(a, "limit", 25);
	if (limit > 40) limit = 40;

	local out = [];
	local total = 0;
	foreach (i, _ in GSIndustryList()) {
		local type = GSIndustry.GetIndustryType(i);
		if (words.len() > 0) {
			local text = GSIndustry.GetName(i) + " " + GSIndustryType.GetName(type) + " " +
				GSTown.GetName(GSTile.GetClosestTown(GSIndustry.GetLocation(i)));
			if (!MatchesAllWords(text, words)) continue;
		}
		if (cargo != null) {
			local p = GSIndustryType.GetProducedCargo(type).HasItem(cargo);
			local c = GSIndustryType.GetAcceptedCargo(type).HasItem(cargo);
			if (role == "produces" && !p) continue;
			if (role == "accepts" && !c) continue;
			if (!p && !c) continue;
		}
		total++;
		if (total > offset && out.len() < limit) out.append(IndustryInfo(i));
	}
	return { ok = true, data = { total = total, offset = offset, industries = out } };
}

function CmdListTowns(job) {
	local a = job.args;
	local words = Words(Arg(a, "query", ""));
	local limit = Arg(a, "limit", 25);
	if (limit > 40) limit = 40;
	local list = GSTownList();
	list.Valuate(GSTown.GetPopulation);
	list.Sort(GSList.SORT_BY_VALUE, GSList.SORT_DESCENDING);
	local out = [];
	local total = 0;
	foreach (t, pop in list) {
		if (words.len() > 0 && !MatchesAllWords(GSTown.GetName(t), words)) continue;
		total++;
		if (out.len() < limit) {
			local loc = GSTown.GetLocation(t);
			out.append({ id = t, name = GSTown.GetName(t), population = pop, x = GSMap.GetTileX(loc), y = GSMap.GetTileY(loc) });
		}
	}
	return { ok = true, data = { total = total, towns = out } };
}

function CmdCompanyInfo(job) {
	local c = Arg(job.args, "company", null);
	if (!ValidCompany(c)) return { ok = false, error = "Invalid company" };
	local cm = GSCompanyMode(c);
	local routes = 0;
	foreach (r in g_routes) if (r.company == c) routes++;
	return { ok = true, data = {
		id = c,
		name = GSCompany.GetName(c),
		bank_balance = GSCompany.GetBankBalance(c),
		loan = GSCompany.GetLoanAmount(),
		max_loan = GSCompany.GetMaxLoanAmount(),
		vehicles = GSVehicleList().Count(),
		bot_routes = routes,
		date = "" + GSDate.GetYear(GSDate.GetCurrentDate()) + "-" + GSDate.GetMonth(GSDate.GetCurrentDate())
	} };
}

function CmdListRoutes(job) {
	local c = Arg(job.args, "company", null);
	local out = [];
	foreach (r in g_routes) {
		if (c != null && r.company != c) continue;
		local alive = [];
		local last_year = 0;
		local this_year = 0;
		foreach (v in r.vehicles) {
			if (!GSVehicle.IsValidVehicle(v)) continue;
			alive.append(v);
			last_year += GSVehicle.GetProfitLastYear(v);
			this_year += GSVehicle.GetProfitThisYear(v);
		}
		r.vehicles = alive;
		out.append({
			id = r.id, kind = r.kind,
			from = r.src_name, to = r.dst_name,
			cargo = CargoLabel(r.cargo),
			vehicles = alive.len(),
			profit_this_year = this_year,
			profit_last_year = last_year
		});
	}
	return { ok = true, data = { routes = out } };
}

function CmdAddVehicles(job) {
	local a = job.args;
	local company = Arg(a, "company", null);
	if (!ValidCompany(company)) return { ok = false, error = "Invalid company" };
	local r = FindRoute(Arg(a, "route_id", -1));
	if (r == null || r.company != company) return { ok = false, error = "No such route for your company" };
	if (r.kind != "road") return { ok = false, error = "Rail lines are single track with no passing loops, so only one train can run safely. Build another line instead." };
	local count = Arg(a, "count", 1);
	if (count < 1) count = 1;
	if (count > 10) count = 10;
	local cm = GSCompanyMode(company);
	if (!GSEngine.IsBuildable(r.engine)) return { ok = false, error = "That truck model can no longer be bought" };
	if (!EnsureMoney(GSEngine.GetPrice(r.engine) * count, Arg(a, "allow_loan", true))) return { ok = false, error = "Not enough money" };
	local share = null;
	foreach (v in r.vehicles) if (GSVehicle.IsValidVehicle(v)) { share = v; break; }
	if (share == null) return { ok = false, error = "Route has no remaining vehicles to copy orders from" };
	GSRoad.SetCurrentRoadType(GSEngine.GetRoadType(r.engine));
	local added = 0;
	for (local i = 0; i < count; i++) {
		local v = BuildTruck(r.depot, r.engine, r.cargo, null, null, share);
		if (typeof v == "string") {
			if (added == 0) return { ok = false, error = v };
			break;
		}
		r.vehicles.append(v);
		added++;
		GSController.Sleep(15);
	}
	return { ok = true, data = { route_id = r.id, added = added, vehicles = r.vehicles.len() } };
}

/* Read-only commands run immediately, even while a build job is in progress. */
QUICK_COMMANDS <- {
	ping = CmdPing,
	list_industries = CmdListIndustries,
	list_towns = CmdListTowns,
	company_info = CmdCompanyInfo,
	list_routes = CmdListRoutes
};

/* Build commands are queued and run one at a time. */
JOB_COMMANDS <- {
	build_rail_line = CmdBuildRailLine,
	build_road_route = CmdBuildRoadRoute,
	add_vehicles = CmdAddVehicles
};
