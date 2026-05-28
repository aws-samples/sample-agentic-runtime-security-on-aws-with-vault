<script lang="ts">
	/**
	 * UserAvatarMenu.svelte — Per-user round photo avatar for the header user menu.
	 *
	 * Renders the logged-in user's profile photo as a round avatar cropped to a
	 * consistent circle regardless of the source image dimensions (square JPEG for
	 * oscar, landscape WebP for jaime). Falls back to the Carbon UserAvatar icon
	 * when the identity does not map to a known image.
	 *
	 * Props:
	 *   displayName  — decoded display name from the id_token (display-only)
	 *   sub          — decoded sub from the id_token ('oscar' | 'jaime' | '')
	 */

	import UserAvatar from 'carbon-icons-svelte/lib/UserAvatar.svelte';
	import oscarAvatar from '$lib/assets/avatars/oscar.jpeg';
	import jaimeAvatar from '$lib/assets/avatars/jaime.webp';

	interface Props {
		displayName?: string;
		sub?: string;
	}

	let { displayName = '', sub = '' }: Props = $props();

	// Map sub → avatar image URL (Vite-hashed at build time)
	const AVATAR_MAP: Record<string, string> = {
		oscar: oscarAvatar,
		jaime: jaimeAvatar
	};

	let avatarSrc = $derived(AVATAR_MAP[sub] ?? '');
</script>

{#if avatarSrc}
	<img
		class="user-avatar"
		src={avatarSrc}
		alt={displayName || sub || 'User avatar'}
		aria-hidden="true"
	/>
{:else}
	<!-- Carbon UserAvatar icon fallback when identity decode fails or sub is unknown -->
	<UserAvatar size={20} />
{/if}

<style>
	.user-avatar {
		width: 28px;
		height: 28px;
		border-radius: 50%;
		object-fit: cover;
		display: block;
		/* Subtle ring to delineate the circle on the light g10 header */
		box-shadow: 0 0 0 1.5px rgba(0, 0, 0, 0.15);
	}
</style>
