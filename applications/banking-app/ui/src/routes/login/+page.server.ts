/**
 * /login — SvelteKit form action for ROPC (Resource Owner Password Credentials) login.
 *
 * The landing page (+page.svelte) hosts the login form with action="/login".
 * This module handles the form POST:
 *   1. Reads username + password from request.formData()
 *   2. Reads IVIA_ISSUER, IVIA_CLIENT_ID, IVIA_CLIENT_SECRET from $env/dynamic/private
 *   3. Calls passwordGrant() — POSTs grant_type=password to IVIA /oauth2/token
 *   4. On success: sets httpOnly cookies (access_token, id_token, refresh_token)
 *      and redirects 302 to /dashboard
 *   5. On error: redirects to /?error=login_failed
 *
 * Reference: ibm-verify-login/src/routes/auth/+page.server.ts
 *
 * Note: IVIA_CLIENT_SECRET is set in the banking-ui-config ConfigMap by the
 * uc2_agent Terraform module. In this workshop environment, a ConfigMap is
 * acceptable. Production deployments should use a Kubernetes Secret.
 */

import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import type { Actions } from './$types';
import { passwordGrant, IBMVerifyError } from '$lib/auth';

export const actions: Actions = {
  default: async ({ request, cookies }) => {
    const data = await request.formData();
    const username = data.get('username')?.toString() ?? '';
    const password = data.get('password')?.toString() ?? '';

    const baseUri = env.IVIA_ISSUER ?? '';
    const clientId = env.IVIA_CLIENT_ID ?? 'agent-uc2';
    // IVIA_CLIENT_SECRET comes from the banking-ui-config ConfigMap wired from
    // the verify_access Terraform output. Empty string is passed as-is — IVIA
    // accepts it for clients configured with client_secret_post auth method.
    const clientSecret = env.IVIA_CLIENT_SECRET ?? '';

    if (!baseUri) {
      console.error('IVIA_ISSUER not set — cannot perform ROPC login');
      throw redirect(302, '/?error=login_failed');
    }

    let tokens;
    try {
      tokens = await passwordGrant(baseUri, {
        clientId,
        clientSecret,
        username,
        password,
        scope: 'openid profile email'
      });
    } catch (err) {
      if (err instanceof IBMVerifyError) {
        console.error('ROPC login failed:', JSON.stringify(err.body));
      } else {
        console.error('ROPC login error:', err);
      }
      throw redirect(302, '/?error=login_failed');
    }

    // Store access_token in httpOnly cookie — forwarded to agent in Authorization header
    cookies.set('access_token', tokens.access_token, {
      path: '/',
      httpOnly: true,
      secure: false, // HTTP-only ALB — lab environment; use true in production
      sameSite: 'lax',
      maxAge: tokens.expires_in
    });

    // Store id_token if present — contains user claims (sub, email, name)
    if (tokens.id_token) {
      cookies.set('id_token', tokens.id_token, {
        path: '/',
        httpOnly: true,
        secure: false,
        sameSite: 'lax',
        maxAge: 60 * 60 * 24 // 24h default if expires_in not in id_token
      });
    }

    // Store refresh_token if IVIA issued one
    if (tokens.refresh_token) {
      cookies.set('refresh_token', tokens.refresh_token, {
        path: '/',
        httpOnly: true,
        secure: false,
        sameSite: 'lax',
        maxAge: 60 * 60 * 24 * 30 // 30 days
      });
    }

    throw redirect(302, '/dashboard');
  }
};
