import type { Step } from "../core";

// TODO: Refactor this to be lazy against cartesian products
export type Captures<B> = Record<string, B>;
export type Captured<A, B> = { value: A; captures: Captures<B> };
export type CapturedStep<A, B> = Step<Captured<A, B>>;

export const sum = <B>(b1: Captures<B>, b2: Captures<B>) => ({
  ...b1,
  ...b2,
});

export const empty: Captures<any> = {};

export const lift = <A>(a: A) => ({ value: a, captures: empty });

export const bind =
  <A, B = any>(sa: Step<A>): CapturedStep<A, B> =>
  ({ value: a, captures }) =>
    sa(a).map(x => ({ value: x, captures }));

export const bindWith =
  <A, B = any>(fb: (_: A) => Captures<B>) =>
  (sa: Step<A>): CapturedStep<A, B> =>
  ({ value: a, captures: b1 }) => {
    const b2 = fb(a);
    return sa(a).map(x => ({ value: x, captures: sum(b1, b2) }));
  };

export const bindWith2 =
  <A, B = any>(fb: (_: Captured<A, B>) => Captures<B>) =>
  (sa: Step<A>): CapturedStep<A, B> =>
  ({ value: a, captures: b1 }) => {
    const b2 = fb(lift(a));
    return sa(a).map(x => ({ value: x, captures: sum(b1, b2) }));
  };
