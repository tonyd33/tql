export type Stream<A> = A[];
export type Step<A> = (a: A) => Stream<A>;

export const unit: <A>(_: A) => Step<A> = n => _ => [n];
export const predicate: <A>(_: (_: A) => boolean) => Step<A> = p => n =>
  p(n) ? [n] : [];
export const kleisli: <A>(p1: Step<A>, p2: Step<A>) => Step<A> =
  (p1, p2) => n =>
    p1(n).flatMap(p2);
export const compose = <A>(...ps: Step<A>[]): Step<A> =>
  ps.reduce(kleisli, x => [x]);

export const runPath: <A>(s: Stream<A>, st: Step<A>) => Stream<A> = (s, st) =>
  s.flatMap(st);
