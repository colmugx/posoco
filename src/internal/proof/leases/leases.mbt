///|
pub(all) struct VersionLeaseState {
  active : Bool
  revoked : Bool
  op_held : Bool
  retained_count : Int32
  refs : Int32
  retiring : Bool
  revision : Int32
}

///|
pub fn version_init(
  revision : Int32,
) -> VersionLeaseState where {
  proof_require: revision >= 1,
  proof_ensure: result => lease_inv(result),
  proof_ensure: result => {
    result.active &&
    !result.revoked &&
    result.refs == 0 &&
    result.revision == revision
  },
} {
  {
    active: true,
    revoked: false,
    op_held: false,
    retained_count: 0,
    refs: 0,
    retiring: false,
    revision,
  }
}

///|
pub fn apply_soft_withdraw(
  s : VersionLeaseState,
) -> VersionLeaseState where {
  proof_require: lease_inv(s) && s.revision < 2_147_483_647,
  proof_ensure: result => lease_inv(result),
  proof_ensure: result => {
    !result.active &&
    result.revoked == s.revoked &&
    result.refs == s.refs &&
    result.revision >= s.revision
  },
} {
  if s.active {
    {
      active: false,
      revoked: s.revoked,
      op_held: s.op_held,
      retained_count: s.retained_count,
      refs: s.refs,
      retiring: s.retiring,
      revision: s.revision + 1,
    }
  } else {
    s
  }
}

///|
pub fn apply_hard_withdraw(
  s : VersionLeaseState,
) -> VersionLeaseState where {
  proof_require: lease_inv(s) && s.revision < 2_147_483_647,
  proof_ensure: result => lease_inv(result),
  proof_ensure: result => {
    !result.active &&
    result.revoked &&
    result.refs == s.refs &&
    result.revision >= s.revision
  },
} {
  if s.revoked {
    s
  } else {
    {
      active: false,
      revoked: true,
      op_held: s.op_held,
      retained_count: s.retained_count,
      refs: s.refs,
      retiring: s.retiring,
      revision: s.revision + 1,
    }
  }
}

///|
pub fn acquire_operation(
  s : VersionLeaseState,
) -> VersionLeaseState where {
  proof_require: lease_inv(s) && s.refs < 2_147_483_647,
  proof_ensure: result => lease_inv(result),
  proof_ensure: result => result.op_held && result.revoked == s.revoked,
  proof_ensure: result => {
    if s.op_held {
      result.refs == s.refs
    } else {
      result.refs == s.refs + 1
    }
  },
} {
  if s.op_held {
    s
  } else {
    {
      active: s.active,
      revoked: s.revoked,
      op_held: true,
      retained_count: s.retained_count,
      refs: s.refs + 1,
      retiring: s.retiring,
      revision: s.revision,
    }
  }
}

///|
pub fn release_operation(
  s : VersionLeaseState,
  unconfirmed : Bool,
) -> VersionLeaseState where {
  proof_require: lease_inv(s) && s.retained_count < 2_147_483_647,
  proof_ensure: result => lease_inv(result),
  proof_ensure: result => !result.op_held && result.revoked == s.revoked,
  proof_ensure: result => release_operation_post(s, unconfirmed, result),
} {
  if !s.op_held {
    s
  } else if unconfirmed {
    {
      active: s.active,
      revoked: s.revoked,
      op_held: false,
      retained_count: s.retained_count + 1,
      refs: s.refs,
      retiring: s.retiring,
      revision: s.revision,
    }
  } else {
    {
      active: s.active,
      revoked: s.revoked,
      op_held: false,
      retained_count: s.retained_count,
      refs: s.refs - 1,
      retiring: s.retiring,
      revision: s.revision,
    }
  }
}

///|
pub fn release_retained(
  s : VersionLeaseState,
  unconfirmed : Bool,
) -> VersionLeaseState where {
  proof_require: lease_inv(s),
  proof_ensure: result => lease_inv(result),
  proof_ensure: result => result.revoked == s.revoked,
  proof_ensure: result => release_retained_post(s, unconfirmed, result),
} {
  if unconfirmed || s.retained_count == 0 {
    s
  } else {
    {
      active: s.active,
      revoked: s.revoked,
      op_held: s.op_held,
      retained_count: 0,
      refs: s.refs - s.retained_count,
      retiring: s.retiring,
      revision: s.revision,
    }
  }
}

///|
pub fn can_retire(
  s : VersionLeaseState,
) -> Bool where {
  proof_require: lease_inv(s),
  proof_ensure: result => result == (!s.active && s.refs == 0 && !s.retiring),
} {
  !s.active && s.refs == 0 && !s.retiring
}
