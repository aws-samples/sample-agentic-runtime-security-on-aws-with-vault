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
		// interface Platform {}
	}
}

export {};
