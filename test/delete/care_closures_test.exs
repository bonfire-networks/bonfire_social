defmodule Bonfire.Social.CareClosuresTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Data.Identity.Caretaker
  alias Bonfire.Me.Fake
  alias Bonfire.Social.Objects

  test "includes nested dependents but excludes unrelated branches and ancestors" do
    ancestor = Fake.fake_user!()
    root = Fake.fake_user!()
    child = Fake.fake_user!()
    grandchild = Fake.fake_user!()
    unrelated = Fake.fake_user!()

    set_caretaker(root, ancestor)
    set_caretaker(child, root)
    set_caretaker(grandchild, child)

    ids = closure_ids(root)

    assert root.id in ids
    assert child.id in ids
    assert grandchild.id in ids
    refute ancestor.id in ids
    refute unrelated.id in ids
    assert Enum.uniq(ids) == ids
  end

  test "deduplicates overlapping and repeated roots" do
    root = Fake.fake_user!()
    child = Fake.fake_user!()
    grandchild = Fake.fake_user!()

    set_caretaker(child, root)
    set_caretaker(grandchild, child)

    expected = closure_ids(root) |> Enum.sort()
    actual = closure_ids([root.id, child.id, root.id]) |> Enum.sort()

    assert actual == expected
  end

  test "terminates for cycles and returns each reachable pointer once" do
    root = Fake.fake_user!()
    child = Fake.fake_user!()

    set_caretaker(child, root)
    set_caretaker(root, child)

    Ecto.Adapters.SQL.query!(repo(), "SET LOCAL statement_timeout = '2s'", [])
    ids = closure_ids(root)

    assert root.id in ids
    assert child.id in ids
    assert Enum.uniq(ids) == ids
  end

  test "terminates for a self caretaker" do
    root = Fake.fake_user!()
    set_caretaker(root, root)

    Ecto.Adapters.SQL.query!(repo(), "SET LOCAL statement_timeout = '2s'", [])
    ids = closure_ids(root)

    assert root.id in ids
    assert Enum.uniq(ids) == ids
  end

  test "empty and missing roots return nothing" do
    assert Objects.care_closures([]) == []
    assert Objects.care_closures([Needle.UID.generate()]) == []
  end

  test "user deletion removes nested dependents and preserves unrelated posts" do
    user = Fake.fake_user!()
    other_user = Fake.fake_user!()
    child = Bonfire.Posts.Fake.fake_post!(user)
    grandchild = Bonfire.Posts.Fake.fake_post!(user)
    unrelated = Bonfire.Posts.Fake.fake_post!(other_user)
    set_caretaker(grandchild, child)

    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(user)

    deleted_ids = [user.id, child.id, grandchild.id]

    refute repo().exists?(
             from(p in Needle.Pointer, where: p.id in ^deleted_ids and is_nil(p.deleted_at))
           )

    assert repo().exists?(
             from(p in Needle.Pointer, where: p.id == ^unrelated.id and is_nil(p.deleted_at))
           )
  end

  defp closure_ids(roots) do
    roots
    |> Objects.care_closures()
    |> Enum.map(& &1.id)
  end

  defp set_caretaker(object, caretaker) do
    %Caretaker{id: object.id, caretaker_id: caretaker.id}
    |> repo().insert!(on_conflict: {:replace, [:caretaker_id]}, conflict_target: [:id])
  end
end
