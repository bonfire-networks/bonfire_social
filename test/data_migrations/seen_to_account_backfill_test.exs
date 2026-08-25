defmodule Bonfire.Social.DataMigrations.SeenToAccountBackfillTest do
  use Bonfire.Social.DataCase

  import Ecto.Query
  alias Bonfire.Common.Repo
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.DataMigrations.SeenToAccountBackfill

  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]

  defp seen_tid, do: Bonfire.Common.Types.table_id(Bonfire.Data.Social.Seen)

  # insert a Seen edge directly with the given subject — bypasses `normalize_subject!` (which now
  # resolves to the account) to reproduce a legacy USER-subject straggler
  defp insert_seen_edge(subject_id, object_id) do
    pointer_id = Needle.ULID.generate()
    {1, _} = Repo.insert_all(Needle.Pointer, [%{id: pointer_id, table_id: seen_tid()}])

    {1, _} =
      Repo.insert_all(Edge, [
        %{id: pointer_id, subject_id: subject_id, object_id: object_id, table_id: seen_tid()}
      ])

    pointer_id
  end

  defp run_backfill do
    # base_query already filters to user-subject Seen edges (with the dumped table_id); the sandbox
    # isolates this test's rows, and post-Fix-A fixtures only ever write account-subject edges (which
    # this query skips), so it returns just the stragglers we inserted
    SeenToAccountBackfill.base_query()
    |> Repo.all()
    |> SeenToAccountBackfill.migrate()
  end

  defp seen_subjects(object_id) do
    tid = seen_tid()

    Repo.all(
      from(e in Edge,
        where: e.table_id == ^tid and e.object_id == ^object_id,
        select: e.subject_id
      )
    )
  end

  test "remaps a user-subject Seen edge to the user's account" do
    account = Fake.fake_account!()
    alice = Fake.fake_user!(account)
    post = fake_post!(alice, "public")

    edge_id = insert_seen_edge(alice.id, post.id)
    assert seen_subjects(post.id) == [alice.id]

    run_backfill()

    assert seen_subjects(post.id) == [account.id]
    # same row, subject rewritten in place
    assert Repo.get(Edge, edge_id).subject_id == account.id
  end

  test "deletes the user-subject edge when the account already saw the object (unique conflict)" do
    account = Fake.fake_account!()
    alice = Fake.fake_user!(account)
    post = fake_post!(alice, "public")

    account_edge = insert_seen_edge(account.id, post.id)
    user_edge = insert_seen_edge(alice.id, post.id)
    assert length(seen_subjects(post.id)) == 2

    run_backfill()

    # the user edge is deleted (account already had one); only the account edge remains
    assert seen_subjects(post.id) == [account.id]
    assert is_nil(Repo.get(Edge, user_edge))
    assert Repo.get(Edge, account_edge).subject_id == account.id
  end
end
