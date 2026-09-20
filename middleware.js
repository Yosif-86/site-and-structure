// Gates every page on this Vercel deployment behind HTTP Basic Auth except
// /api/* -- the mobile app is the only intended client now, and it talks
// straight to the API routes with a Bearer token, never loads a web page,
// so it's completely unaffected by this. The teacher-invite flow that used
// to require index.html has moved into the app itself (AuthScreen's "Have
// an invite code?"), so there's no remaining reason for any page here to be
// publicly reachable.
//
// Credentials come from env vars, not hardcoded, so they can be rotated
// from the Vercel dashboard without a redeploy of this file:
//   Project Settings -> Environment Variables -> SITE_BASIC_AUTH_USER / SITE_BASIC_AUTH_PASS
//
// If those vars aren't set, this fails OPEN (no gate) rather than locking
// everyone out -- better to notice an unprotected site than to be unable
// to log into your own admin dashboard.
export const config = {
  matcher: ['/((?!api/).*)'],
};

export default function middleware(request) {
  const user = process.env.SITE_BASIC_AUTH_USER;
  const pass = process.env.SITE_BASIC_AUTH_PASS;
  if (!user || !pass) return;

  const expected = 'Basic ' + btoa(`${user}:${pass}`);
  const provided = request.headers.get('authorization');
  if (provided === expected) return;

  return new Response('Authentication required.', {
    status: 401,
    headers: { 'WWW-Authenticate': 'Basic realm="Site & Structure"' },
  });
}
