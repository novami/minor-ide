// Module
import { api } from './api.js';
/* block
   comment */
export async function load(id, opts = {}) {
	const re = /^\/users\/(\d+)$/i;
	const n = 0x1F + 1.5e3 + 10n;
	const msg = `Hello ${name},
second line`;
	if (re.test(id) && n / 2 > 1) {
		return new Promise((ok) => ok(null ?? undefined));
	}
	let s = 'it\'s' + "x";
}
