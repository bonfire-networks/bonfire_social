# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.PaginationLinkTest do
  @moduledoc """
  Phase 1 characterization safety net (TDD): pins the RFC-5988 Link-header
  pagination contract the conversions depend on.

  - The `next` link must round-trip to a distinct next page (pins the cursor contract).
  - The `next` link must preserve non-pagination query params (e.g. `local=true`).
  """

  use Bonfire.Social.MastoApiCase, async: false

  alias Bonfire.Me.Fake
  alias Bonfire.Posts

  @moduletag :masto_api

  setup do
    Process.put(:feed_live_update_many_preload_mode, :inline)
    :ok
  end

  defp ids(list) when is_list(list), do: Enum.map(list, & &1["id"])

  # Extract the path+query of the URL for the given rel from a Link header value.
  defp rel_path(nil, _rel), do: nil

  defp rel_path(link_header, rel) do
    link_header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      with [_, url] <- Regex.run(~r/<([^>]+)>/, part),
           true <- String.contains?(part, "rel=\"#{rel}\"") do
        uri = URI.parse(url)
        if uri.query, do: uri.path <> "?" <> uri.query, else: uri.path
      else
        _ -> nil
      end
    end)
  end

  defp next_link(conn) do
    conn |> Plug.Conn.get_resp_header("link") |> List.first() |> rel_path("next")
  end

  test "next-rel Link round-trips to a distinct page", %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    for i <- 1..5 do
      {:ok, _} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "paginate #{i}"}},
          boundary: "public"
        )
    end

    api_conn = masto_api_conn(conn, user: author, account: account)

    page1_conn = get(api_conn, "/api/v1/timelines/public?limit=2")
    page1 = json_response(page1_conn, 200)
    assert length(page1) == 2

    next = next_link(page1_conn)
    assert next, "page 1 should expose a next-rel Link header"

    page2 = api_conn |> get(next) |> json_response(200)

    assert MapSet.disjoint?(MapSet.new(ids(page1)), MapSet.new(ids(page2))),
           "the next page must not repeat page-1 items"
  end

  # Phase 3 (DONE): the next-link preserves non-pagination query params, so a
  # filtered timeline keeps its filter on page 2 (only the cursor key is swapped).
  test "next-rel Link preserves non-pagination query params", %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)

    for i <- 1..3 do
      {:ok, _} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "local #{i}"}},
          boundary: "public"
        )
    end

    api_conn = masto_api_conn(conn, user: author, account: account)
    page1_conn = get(api_conn, "/api/v1/timelines/public?local=true&limit=2")
    next = next_link(page1_conn)

    assert next && String.contains?(next, "local=true"),
           "next-link must preserve the local=true filter"
  end
end
