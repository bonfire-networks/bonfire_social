defmodule Bonfire.Social.Feeds.BucketsTest do
  @moduledoc """
  Phase 1A of the local-remote-feeds plan: the origin×boundary feed buckets are registered as named
  feed-id pointers. `Feeds.named_feed_id/1` must resolve all 5 bucket names to their fixture ULIDs
  (3 new + 2 legacy reuses), and the 3 new pointers must actually be seeded (Phase-1B writes FK against them).
  """
  use Bonfire.Social.DataCase, async: true

  import Ecto.Query
  alias Bonfire.Social.Feeds

  # the canonical bucket → feed-id map (must match `config :bonfire_boundaries, :circles` and the plan)
  @buckets %{
    local_public: "7PVB11C0BJECTFR0M10CA1VSER",
    local_instance_only: "710CA10BJ0N1YF0R10CA1VSERS",
    local_custom: "3SERSFR0MY0VR10CA11NSTANCE",
    remote_public: "7PVB11C0BJFR0MAREM0TEACT0R",
    remote_custom: "7EDERATEDW1THANACT1V1TYPVB"
  }

  test "every bucket name resolves to its fixture feed id" do
    for {name, id} <- @buckets do
      assert Feeds.named_feed_id(name) == id, "expected #{name} to resolve to #{id}"
    end
  end

  test "the _custom buckets alias the legacy feed ids (no separate pointer)" do
    assert Feeds.named_feed_id(:local_custom) == Feeds.named_feed_id(:local)
    assert Feeds.named_feed_id(:remote_custom) == Feeds.named_feed_id(:activity_pub)
  end

  test "concept feed-id helpers are legacy ∪ bucket unions (explore = guest ∪ local ∪ remote)" do
    assert Enum.sort(Feeds.named_feed_ids(:local)) ==
             Enum.sort([
               # legacy :local (= local_custom)
               "3SERSFR0MY0VR10CA11NSTANCE",
               "7PVB11C0BJECTFR0M10CA1VSER",
               "710CA10BJ0N1YF0R10CA1VSERS"
             ])

    assert Enum.sort(Feeds.named_feed_ids(:remote)) ==
             Enum.sort([
               # legacy :activity_pub (= remote_custom)
               "7EDERATEDW1THANACT1V1TYPVB",
               "7PVB11C0BJFR0MAREM0TEACT0R"
             ])

    assert Enum.sort(Feeds.named_feed_ids(:public)) ==
             Enum.sort([
               "0AND0MSTRANGERS0FF1NTERNET",
               "7PVB11C0BJECTFR0M10CA1VSER",
               "7PVB11C0BJFR0MAREM0TEACT0R"
             ])

    assert Enum.sort(Feeds.named_feed_ids(:explore)) ==
             Enum.sort(
               Feeds.named_feed_ids(:local) ++
                 Feeds.named_feed_ids(:remote) ++ ["0AND0MSTRANGERS0FF1NTERNET"]
             )
  end

  test "the 3 new bucket pointers are seeded (so Phase-1B feed_publish writes can FK against them)" do
    # the FK on feed_publish.feed_id references the Pointer table directly, that's what must exist.
    # (Needles.get/one is NOT a valid check here: it returns :not_found even for the legacy `local` feed id that works in prod, because circles aren't returned by generic Needle object queries.)
    new_ids =
      for name <- [:local_public, :local_instance_only, :remote_public],
          do: Feeds.named_feed_id(name)

    seeded = repo().all(from(p in Needle.Pointer, where: p.id in ^new_ids, select: p.id))

    assert Enum.sort(seeded) == Enum.sort(new_ids),
           "expected all 3 new bucket pointers seeded, got: #{inspect(seeded)}"
  end
end
