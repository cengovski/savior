import { COOKIE } from '../lib/session.js';
import { redirect } from '../lib/http.js';
export default function handler(req, res) {
  redirect(res, '/login', { 'Set-Cookie': `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0` });
}
