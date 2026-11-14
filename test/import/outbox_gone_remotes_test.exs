defmodule Bonfire.Social.Import.OutboxGoneRemotesTest do
  @moduledoc """
  An outbox import still brings in a person's posts when the servers it references can no longer answer: a 410, a 404, an unreachable host, or a page that isn't ActivityPub JSON. The posts are embedded in the outbox, so they need no fetch, and each imported post is listed in the importer's outbox without being delivered to anyone.
  """
  use Bonfire.Social.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Social.Import
  alias Bonfire.Social.Boosts
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @moduletag :backend

  @public "https://www.w3.org/ns/activitystreams#Public"
  @failures [:gone, :not_found, :unreachable, :html]

  setup do
    {:ok, requests} = Agent.start_link(fn -> %{} end)
    {:ok, user: fake_user!(), requests: requests}
  end

  # every GET is answered from `served`, a map of url to a failure kind or `{:json, document}`, and counted per url
  defp serve(requests, served) do
    mock_global(fn %{method: :get, url: url} ->
      Agent.update(requests, &Map.update(&1, url, 1, fn n -> n + 1 end))

      case Map.get(served, url, :not_found) do
        :gone ->
          %Tesla.Env{status: 410, body: ""}

        :not_found ->
          %Tesla.Env{status: 404, body: ""}

        :unreachable ->
          {:error, :econnrefused}

        :html ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "text/html"}],
            body: "<html><body>This account has been deleted</body></html>"
          }

        {:json, document} ->
          %Tesla.Env{
            status: 200,
            headers: ActivityPub.Utils.activitypub_object_headers(),
            body: Jason.encode!(document)
          }
      end
    end)
  end

  defp requests_to(requests, url), do: Agent.get(requests, &Map.get(&1, url, 0))

  defp host, do: "origin-#{System.unique_integer([:positive])}.local"

  defp note(author, fields \\ %{}) do
    Map.merge(
      %{
        "id" => "#{author}/statuses/#{System.unique_integer([:positive])}",
        "type" => "Note",
        "attributedTo" => author,
        "content" => "<p>written before the account was deleted</p>",
        "published" => "2020-01-02T03:04:05Z",
        "to" => [@public]
      },
      fields
    )
  end

  defp create(%{"id" => id, "attributedTo" => author} = object) do
    %{
      "id" => "#{id}/activity",
      "type" => "Create",
      "actor" => author,
      "published" => object["published"],
      "to" => [@public],
      "object" => object
    }
  end

  # two keys made once for the module, since a 2048-bit RSA key is slow to generate: the live actor and the uploaded copy of it need different ones
  setup_all do
    [key_a, key_b] =
      for _ <- 1..2 do
        {:ok, pem} = ActivityPub.Safety.Keys.generate_rsa_pem()
        {:ok, _private, public} = ActivityPub.Safety.Keys.keypair_from_pem(pem)
        :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])
      end

    {:ok, key_a: key_a, key_b: key_b}
  end

  defp actor_document(id, host, public_pem) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Person",
      "preferredUsername" => "old_#{System.unique_integer([:positive])}",
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox",
      "url" => "https://#{host}/@old",
      "publicKey" => %{
        "id" => "#{id}#main-key",
        "owner" => id,
        "publicKeyPem" => public_pem
      }
    }
  end

  defp outbox(items), do: %{"type" => "OrderedCollection", "orderedItems" => items}

  defp import!(user, items, opts \\ []) do
    Import.import_from_json(:outbox, user, outbox(items), opts)
    Oban.drain_queue(queue: :import)
  end

  defp pointer_id(ap_id) do
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id)
    pointer_id
  end

  defp creator_id(pointer_id),
    do: Bonfire.Common.Repo.get(Bonfire.Data.Social.Created, pointer_id).creator_id

  for failure <- @failures do
    describe "when the author's server answers #{failure}" do
      test "an embedded post imports and the importer boosts it", %{
        user: user,
        requests: requests
      } do
        author = "https://#{host()}/users/gone"
        serve(requests, %{author => unquote(failure)})
        post = note(author)

        assert %{success: 1} = import!(user, [create(post)])

        assert Boosts.boosted?(user, pointer_id(post["id"]))
      end

      test "two posts by the same author request the author once", %{
        user: user,
        requests: requests
      } do
        author = "https://#{host()}/users/gone"
        serve(requests, %{author => unquote(failure)})

        # the AP cache is off in tests unless asked for, and remembering a failed fetch is what this is about
        Process.put(:activity_pub_enable_cache, true)

        assert %{success: 2} = import!(user, [create(note(author)), create(note(author))])

        assert requests_to(requests, author) == 1
      end

      test "a bare-url post that can't be fetched fails alone, the rest import", %{
        user: user,
        requests: requests
      } do
        author = "https://#{host()}/users/gone"
        gone_post = "#{author}/statuses/1"
        serve(requests, %{author => unquote(failure), gone_post => unquote(failure)})
        post = note(author)

        bare = %{"id" => "#{gone_post}/activity", "type" => "Create", "object" => gone_post}

        assert %{success: 1, discard: 1} = import!(user, [bare, create(post)])

        assert Boosts.boosted?(user, pointer_id(post["id"]))
      end

      test "a reply whose parent can't be fetched imports", %{user: user, requests: requests} do
        author = "https://#{host()}/users/gone"
        parent = "https://#{host()}/statuses/parent"
        serve(requests, %{author => unquote(failure), parent => unquote(failure)})
        reply = note(author, %{"inReplyTo" => parent})

        assert %{success: 1} = import!(user, [create(reply)])

        assert Boosts.boosted?(user, pointer_id(reply["id"]))
      end

      test "the archive's actor document becomes the author", %{
        user: user,
        requests: requests,
        key_a: key
      } do
        host = host()
        author = "https://#{host}/users/gone"
        serve(requests, %{author => unquote(failure)})
        actor = actor_document(author, host, key)
        post = note(author)

        assert %{success: 1} = import!(user, [create(post)], actor: actor)

        assert {:ok, character} = AdapterUtils.get_character_by_ap_id(author)
        assert creator_id(pointer_id(post["id"])) == id(character)
        assert e(character, :character, :username, nil) =~ actor["preferredUsername"]

        # an uploaded document can be forged, so it's neither trusted nor allowed to vouch for signatures
        assert {:ok, stored} = ActivityPub.Object.get_cached(ap_id: author)
        refute stored.data["publicKey"]
        assert stored.authenticated == :unverified
      end
    end
  end

  test "the archive's actor document is ignored when the author's server answers", %{
    user: user,
    requests: requests,
    key_a: key_a,
    key_b: key_b
  } do
    host = host()
    author = "https://#{host}/users/alive"
    live = actor_document(author, host, key_a)
    uploaded = actor_document(author, host, key_b)
    serve(requests, %{author => {:json, live}})

    assert %{success: 1} = import!(user, [create(note(author))], actor: uploaded)

    assert {:ok, stored} = ActivityPub.Object.get_cached(ap_id: author)
    assert stored.data["publicKey"]["publicKeyPem"] == live["publicKey"]["publicKeyPem"]
  end

  test "an actor document that isn't the posts' author is ignored", %{
    user: user,
    requests: requests,
    key_a: key
  } do
    host = host()
    author = "https://#{host}/users/gone"
    other = "https://#{host}/users/someone-else"
    serve(requests, %{author => :gone, other => :gone})

    assert %{success: 1} =
             import!(user, [create(note(author))], actor: actor_document(other, host, key))

    assert {:error, _} = AdapterUtils.get_character_by_ap_id(other)
  end

  test "imported posts are listed in the importer's outbox and not delivered, boosts are not",
       %{user: user, requests: requests, key_a: key_a, key_b: key_b} do
    host = host()
    author = "https://#{host}/users/alive"
    boosted_author = "https://#{host}/users/other"
    boosted = note(boosted_author)
    post = note(author)

    serve(requests, %{
      author => {:json, actor_document(author, host, key_a)},
      boosted_author => {:json, actor_document(boosted_author, host, key_b)},
      boosted["id"] => {:json, boosted}
    })

    announce = %{
      "id" => "#{author}/statuses/boost/activity",
      "type" => "Announce",
      "actor" => author,
      "object" => boosted["id"],
      "to" => [@public]
    }

    assert %{success: 2} = import!(user, [create(post), announce], include_boosts: true)

    assert Boosts.boosted?(user, pointer_id(boosted["id"]))

    importer = Bonfire.Common.URIs.canonical_url(user)

    assert [%{data: %{"type" => "Announce", "object" => object} = listed}] =
             ActivityPub.Object.get_outbox_for_actor(importer, 1)

    assert object == post["id"]
    assert listed["published"] =~ "2020-01-02"

    assert %{success: 0, failure: 0, discard: 0} =
             Oban.drain_queue(queue: :federator_outgoing)
  end

  test "an outbox's boosts are skipped unless asked for", %{
    user: user,
    requests: requests,
    key_a: key
  } do
    host = host()
    boosted_author = "https://#{host}/users/other"
    boosted = note(boosted_author)

    serve(requests, %{
      boosted_author => {:json, actor_document(boosted_author, host, key)},
      boosted["id"] => {:json, boosted}
    })

    announce = %{
      "id" => "https://#{host}/users/me/statuses/boost/activity",
      "type" => "Announce",
      "object" => boosted["id"],
      "to" => [@public]
    }

    # not queued at all, so the boosted post isn't even fetched
    assert %{success: 0} = import!(user, [announce])
    assert requests_to(requests, boosted["id"]) == 0
  end
end
