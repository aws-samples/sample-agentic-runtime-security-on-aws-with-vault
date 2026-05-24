<!--
  Root page. Never actually rendered: +page.server.ts always 302s
  (to /dashboard if authenticated, to IVIA /oauth2/authorize otherwise).
  This minimal markup is a fallback if a request reaches the client.
-->
<div class="redirecting">
  <p>Redirecting…</p>
</div>

<style>
  .redirecting {
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    color: #ffffff;
    font-size: 1rem;
    background: #0f62fe; /* IBM Blue 60 — on-brand loading splash */
  }
</style>
