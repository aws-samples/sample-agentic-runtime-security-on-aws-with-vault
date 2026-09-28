/**
 * The left navigation's collapsed state (the 72px icon rail), remembered per browser.
 *
 * Every navigation link is a full page load, so the choice is kept in localStorage and
 * re-applied on each page. HEAD_SCRIPT runs in <head> before the page is painted and marks
 * <html> with NAV_ATTRIBUTE="collapsed"; the layout's CSS draws the rail from that attribute
 * alone, so a collapsed page never flashes the full navigation first. The layout component
 * reads the same attribute when it starts and keeps it in sync when the viewer toggles.
 *
 * Storage can be unavailable (disabled, blocked, private modes that throw): every read and
 * write is wrapped, and the page then renders the full navigation, as it did before.
 */

export const NAV_STORAGE_KEY = 'ovi-nav';
export const NAV_ATTRIBUTE = 'data-ovi-nav';
export const NAV_COLLAPSED = 'collapsed';
const NAV_EXPANDED = 'expanded';

// Built from the constants above so the key and the attribute live in one place. The tag is
// assembled here, in a .ts file, because a literal script tag inside a .svelte file ends
// that file's own <script> block.
const tag = 'script';
export const HEAD_SCRIPT =
	`<${tag}>try{if(localStorage.getItem(${JSON.stringify(NAV_STORAGE_KEY)})===${JSON.stringify(NAV_COLLAPSED)})` +
	`document.documentElement.setAttribute(${JSON.stringify(NAV_ATTRIBUTE)},${JSON.stringify(NAV_COLLAPSED)})}catch(e){}</${tag}>`;

/** True when the head script marked this page collapsed. Browser only. */
export function isMarkedCollapsed(): boolean {
	return document.documentElement.getAttribute(NAV_ATTRIBUTE) === NAV_COLLAPSED;
}

/** Marks the page and remembers the choice for the next page. Browser only. */
export function setCollapsed(collapsed: boolean): void {
	if (collapsed) document.documentElement.setAttribute(NAV_ATTRIBUTE, NAV_COLLAPSED);
	else document.documentElement.removeAttribute(NAV_ATTRIBUTE);
	try {
		localStorage.setItem(NAV_STORAGE_KEY, collapsed ? NAV_COLLAPSED : NAV_EXPANDED);
	} catch {
		// No storage: the choice holds for this page only.
	}
}
