///|
fn insert_at(
  arr : FixedArray[Int32],
  i : Int32,
  j : Int32,
  key : Int32,
) -> Unit where {
  proof_decrease: j,
  proof_require: 1 <= i && i < arr.length(),
  proof_require: 0 <= j && j <= i,
  proof_require: sorted_upto(arr, j),
  proof_require: sorted_range(arr, j + 1, i + 1),
  proof_require: all_gt_key(arr, j + 1, i + 1, key),
  proof_require: bridge_sorted(arr, j, i + 1),
  proof_ensure: sorted_upto(arr, i + 1),
} {
  if j > 0 && arr[j - 1] > key {
    arr[j] = arr[j - 1]
    proof_assert sorted_upto(arr, j - 1)
    proof_assert sorted_range(arr, j, i + 1)
    proof_assert all_gt_key(arr, j, i + 1, key)
    proof_assert bridge_sorted(arr, j - 1, i + 1)
    insert_at(arr, i, j - 1, key)
  } else {
    arr[j] = key
    proof_assert sorted_upto(arr, i + 1)
  }
}

///|
fn sort_from(
  arr : FixedArray[Int32],
  i : Int32,
  remaining : Int32,
) -> Unit where {
  proof_decrease: remaining,
  proof_require: 1 <= i && i <= arr.length(),
  proof_require: remaining == arr.length() - i,
  proof_require: sorted_upto(arr, i),
  proof_ensure: sorted_upto(arr, arr.length()),
} {
  if remaining > 0 {
    let key = arr[i]
    insert_at(arr, i, i, key)
    sort_from(arr, i + 1, remaining - 1)
  }
}

///|
pub fn insertion_sort_positions(
  arr : FixedArray[Int32],
) -> Unit where {
  proof_ensure: sorted_upto(arr, arr.length()),
} {
  if arr.length() <= 1 {
    ()
  } else {
    sort_from(arr, 1, arr.length() - 1)
  }
}
