<!--
  /login — Minimal route page.

  The ROPC login form lives on the landing page (+page.svelte) with
  action="/login". This file exists so SvelteKit recognizes /login as a
  valid route for the form action POST target.

  GET requests to /login show this page. The form POST goes to
  +page.server.ts actions.default.
-->
<div class="signing-in">
  <p>Signing in...</p>
</div>

<style>
  .signing-in {
    min-height: calc(100vh - 4rem);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--color-text-secondary);
    font-size: 1rem;
  }
</style>
