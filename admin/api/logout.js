import { COOKIE } from '../lib/session.js';
export const config = { runtime: 'edge' };
export default function handler() {
  return new Response(null, { status: 303, headers: {
    Location: '/login', 'Set-Cookie': `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`, 'Cache-Control': 'no-store' } });
}
