/** Contract errors: a non-2xx status and `{error, code}` (plans/api.md). */
export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}
export const notFound = (what: string) => new ApiError(404, 'not_found', `${what} not found`);
export const badRequest = (msg: string) => new ApiError(400, 'bad_request', msg);
export const insufficient = () => new ApiError(402, 'insufficient_balance', 'Not enough balance · top up in Credits');
