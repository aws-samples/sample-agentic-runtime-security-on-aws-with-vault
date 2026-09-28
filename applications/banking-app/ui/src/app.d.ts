// See https://svelte.dev/docs/kit/types#app.d.ts

declare global {
	namespace App {
		// interface Error {}
		interface Locals {
			accessToken: string | null;
		}
		interface PageData {
			accessToken?: string | null;
		}
		// interface PageState {}
		// adapter-node hands every request's Node object over as platform.req
		// (its ambient.d.ts declares the same). There is no platform under vite dev.
		interface Platform {
			req: import('node:http').IncomingMessage;
		}
	}
}

export {};
