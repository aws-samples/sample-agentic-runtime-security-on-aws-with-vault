/**
 * personas.ts — Fictional persona mapping for the workshop's logged-in users.
 *
 * Single source of truth for display name, About Me backstory, Wikipedia link,
 * and the avatar shown both in the header dropdown and on the About Me page.
 *
 * The underlying IVIA `sub` claim stays canonical ('oscar' | 'jaime'); only the
 * UI-facing presentation is dressed up with these fictional Six Million Dollar
 * Man / Bionic Woman personas.
 */

import oscarAvatar from '$lib/assets/avatars/oscar.jpeg';
import jaimeAvatar from '$lib/assets/avatars/jaime.webp';

export interface Persona {
	sub: string;
	fullName: string;
	avatar: string;
	wikipediaUrl?: string;
	tagline: string;
	backstory: string[];
}

export const PERSONAS: Record<string, Persona> = {
	oscar: {
		sub: 'oscar',
		fullName: 'Oscar Goldman',
		avatar: oscarAvatar,
		wikipediaUrl: 'https://en.wikipedia.org/wiki/Oscar_Goldman',
		tagline: 'Director, Office of Scientific Intelligence (OSI)',
		backstory: [
			"Oscar Goldman runs the Office of Scientific Intelligence — the U.S. agency that quietly turns bleeding-edge science into operational capability. From a glass-walled office in Washington he authorizes the missions, signs the budget lines, and answers to the people who ask hard questions about cybernetics and national security.",
			"He recruited Colonel Steve Austin after the test-flight crash that should have killed him, and he stood behind the operating-room door the night Jaime Sommers came back. Goldman believes that giving extraordinary capability to the right person — and trusting them — is a form of engineering all its own.",
			"OscarVault International (OVI) is one of OSI's subsidiaries — a private bank Goldman chartered so the agency's personnel could move money under the same security discipline they live by in the field. Even his own transactions flow through least-privilege tokens, short-lived database leases, and an audit trail that can be replayed end to end. The principles are the same. The stakes still feel personal."
		]
	},
	jaime: {
		sub: 'jaime',
		fullName: 'Jaime Sommers',
		avatar: jaimeAvatar,
		wikipediaUrl: 'https://en.wikipedia.org/wiki/Jaime_Sommers_(The_Bionic_Woman)',
		tagline: 'The Bionic Woman — OSI field operative',
		backstory: [
			"Jaime Sommers was a professional tennis player whose life ended — and began again — after a skydiving accident. Surgeons at the OSI rebuilt her with bionic legs, a bionic right arm, and a bionic right ear: not a replacement of who she was, but an amplification of it.",
			"She runs faster than the cars on the freeway, hears conversations through walls, and can bend steel when the moment demands it. What she carries, though, is harder to measure: the discipline to use those gifts sparingly, the conviction that strength without judgment is just damage waiting to happen.",
			"OscarVault International (OVI) is OSI's banking subsidiary — the in-house institution where Goldman's people, Sommers included, run their financial lives without it ever leaving the agency's perimeter. She insists on the same standards there that she lives by in the field: every action attributable, every privilege the smallest one that gets the job done, every record honest enough to stand up to scrutiny. The bionics are the easy part."
		]
	}
};

/**
 * Resolve a persona from the IVIA sub claim. Returns `null` when the sub does
 * not map to a known fictional persona — callers should fall back to the raw
 * `name` claim (or hide the affordance) in that case.
 */
export function getPersona(sub: string | undefined | null): Persona | null {
	if (!sub) return null;
	return PERSONAS[sub] ?? null;
}
