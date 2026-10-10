// Vercel Routing Middleware: every request except login/static login assets
// requires a valid signed session cookie. Unauthenticated -> /login.
import { COOKIE, verify, getCookie } from './lib/session.js';

export const config = { matcher: ['/((?!login|api/login|favicon).*)'] };

export default async function middleware(req) {
  const secret = process.env.SESSION_SECRET;
  if (!secret || !process.env.ADMIN_PASSWORD) {
    return new Response('Admin not configured', { status: 503 });
  }
  const ok = await verify(getCookie(req, COOKIE), secret);
  if (!ok) {
    const url = new URL('/login', req.url);
    return Response.redirect(url, 302);
  }
  // fall through to the protected page; never cache
}
