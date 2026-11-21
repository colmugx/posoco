///|
pub(all) enum PolicyLevel {
  Parallel
  Sequential
  Exclusive
}

///|
pub fn child_policy_allowed(
  caller : PolicyLevel,
  target : PolicyLevel,
) -> Bool where {
  proof_ensure: result => result == (policy_rank(target) <= policy_rank(caller)),
} {
  match (caller, target) {
    (Parallel, Sequential | Exclusive) | (Sequential, Exclusive) => false
    _ => true
  }
}

///|
pub fn child_depth_allowed(
  parent_depth : Int32,
  max_depth : Int32,
) -> Bool where {
  proof_require: parent_depth >= 0 &&
  max_depth >= 0 &&
  parent_depth < 2_147_483_647,
  proof_ensure: result => result == (parent_depth + 1 <= max_depth),
} {
  parent_depth + 1 <= max_depth
}

///|
pub fn has_pending_child(
  pending_parents : FixedArray[Int32],
  target_parent : Int32,
) -> Bool where {
  proof_ensure: result => {
    result ==
    exists_child_upto(pending_parents, pending_parents.length(), target_parent)
  },
} {
  let n = pending_parents.length()
  for i = 0; i < n; {
    if pending_parents[i] == target_parent {
      break true
    }
    continue i + 1
  } nobreak {
    false
  } where {
    proof_invariant: 0 <= i && i <= n,
    proof_invariant: !exists_child_upto(pending_parents, i, target_parent),
    proof_yield: res => {
      res == exists_child_upto(pending_parents, n, target_parent)
    },
  }
}
