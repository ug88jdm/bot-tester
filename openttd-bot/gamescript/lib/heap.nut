/* Binary min-heap of integer values keyed by integer priority. */
class BinaryHeap {
	prio = null;
	vals = null;

	constructor() {
		this.prio = [];
		this.vals = [];
	}

	function Count() { return this.vals.len(); }
	function IsEmpty() { return this.vals.len() == 0; }

	function Push(p, v) {
		this.prio.append(p);
		this.vals.append(v);
		local i = this.vals.len() - 1;
		while (i > 0) {
			local parent = (i - 1) / 2;
			if (this.prio[parent] <= this.prio[i]) break;
			this._Swap(i, parent);
			i = parent;
		}
	}

	function Pop() {
		local top = this.vals[0];
		local last = this.vals.len() - 1;
		this._Swap(0, last);
		this.prio.pop();
		this.vals.pop();
		local n = this.vals.len();
		local i = 0;
		while (true) {
			local l = i * 2 + 1;
			local r = l + 1;
			local m = i;
			if (l < n && this.prio[l] < this.prio[m]) m = l;
			if (r < n && this.prio[r] < this.prio[m]) m = r;
			if (m == i) break;
			this._Swap(i, m);
			i = m;
		}
		return top;
	}

	function _Swap(a, b) {
		local tp = this.prio[a]; this.prio[a] = this.prio[b]; this.prio[b] = tp;
		local tv = this.vals[a]; this.vals[a] = this.vals[b]; this.vals[b] = tv;
	}
}
