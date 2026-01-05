# Implementing Aggregated Feeds in Bonfire

This document provides a comprehensive guide for implementing aggregated feed features in Bonfire. It was developed during the implementation of the Trending Links feature and serves as a template for similar features (e.g., trending topics, popular discussions, most-boosted posts, active threads).

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Query Layer](#1-query-layer-mediafeedloader)
3. [Context Layer](#2-context-layer-trendinglinks)
4. [Widget Component](#3-widget-component)
5. [Feed Card Component](#4-feed-card-component)
6. [Feed Integration](#5-feed-integration)
7. [Dashboard Integration](#6-dashboard-integration)
8. [Testing](#7-testing)
9. [Complete File Listing](#8-complete-file-listing)
10. [Implementation Checklist](#9-implementation-checklist)

---

## Architecture Overview

Aggregated feeds in Bonfire follow a layered architecture that separates concerns:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            UI LAYER                                      │
│  Renders data to users via LiveView components                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   WidgetTrendingLinksLive          FeedLive                             │
│   ├── Compact sidebar widget       ├── Full-page paginated feed         │
│   ├── Calls list_trending/1        ├── Calls list_trending_paginated/1  │
│   └── No pagination needed         └── Uses FeedControlsLive for filters│
│                                                                          │
│   TrendingLinkCardLive                                                   │
│   ├── Renders individual items in feed                                  │
│   ├── Has "featured" variant for first item                             │
│   └── Shows metadata, sharers, boost counts                             │
│                                                                          │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          CONTEXT LAYER                                   │
│  Business logic, data transformation, pagination                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   TrendingLinks module (extensions/bonfire_social/lib/trending_links.ex)│
│   ├── list_trending/1           Simple list for widgets                 │
│   ├── list_trending_paginated/1 Keyset pagination for feeds             │
│   ├── hydrate_results/1         Loads Media, Users, boost counts        │
│   └── order_pagination_opts/2   Configures cursor fields                │
│                                                                          │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           QUERY LAYER                                    │
│  Builds Ecto queries with aggregations and filtering                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   MediaFeedLoader module (extensions/bonfire_social/lib/media_feed_loader.ex)
│   ├── trending_links_query/1    Main query builder                      │
│   ├── base_query/0              Joins Media -> Files -> Activity        │
│   ├── select_aggregated_fields/1  COUNT, array_agg for grouping        │
│   ├── build_order_by/1          Dynamic ORDER BY based on sort option  │
│   └── maybe_apply_time_limit/2  Filter by date range                   │
│                                                                          │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           DATA LAYER                                     │
│  Ecto schemas and database tables                                        │
├─────────────────────────────────────────────────────────────────────────┤
│   Media, Activity, Bonfire.Files, User, Profile schemas                 │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why This Architecture?

1. **Separation of concerns**: Query logic is isolated from business logic and UI rendering
2. **Reusability**: The same context functions serve both widgets and full feeds
3. **Testability**: Each layer can be tested independently
4. **Performance**: Hydration happens after the main query to avoid N+1 issues

---

## 1. Query Layer (MediaFeedLoader)

**Purpose**: Build Ecto queries with GROUP BY aggregations, filtering, and ordering.

**File location**: `extensions/bonfire_social/lib/media_feed_loader.ex`

### Critical Concept: Subquery Wrapping for GROUP BY

When using GROUP BY with keyset pagination, aggregated fields (like `count()`) cannot be used directly in WHERE clauses. The solution is to wrap the GROUP BY query in a subquery, which converts aggregated results into regular columns.

```elixir
defmodule Bonfire.Social.MediaFeedLoader do
  @moduledoc """
  Builds queries for aggregated media feeds like trending links.

  This module handles the query construction layer, separate from
  the business logic in TrendingLinks module.
  """

  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Data.Social.Activity
  alias Bonfire.Files.Media

  # Media types to EXCLUDE from trending links (we only want article/link previews)
  @exclude_media_types [
    "image", "avatar", "banner", "icon", "photo", "picture",
    "profile", "website", "research", "rich", "object", "remote"
  ]

  @doc """
  Builds query for trending links with aggregations.

  ## Options

  - `:time_limit` - Number of days to look back (default: 7, use 0 for no limit)
  - `:sort_by` - `:popularity` (default) or `:date_created`
  - `:exclude_activity_types` - List of activity verbs to exclude (e.g., `[:reply, :boost]`)

  ## Returns

  An Ecto query that can be passed to `repo().all()` or `repo().many_paginated()`.
  The query returns maps with these fields:

  - `path` - The URL (grouping key)
  - `share_count` - Number of times this URL was shared
  - `first_media_id` - ID of first Media record (for hydration)
  - `newest_activity_id` - Most recent activity ID (for chronological sorting)
  - `activity_ids` - Array of all activity IDs sharing this URL
  - `sharer_ids` - Array of all user IDs who shared this URL
  """
  def trending_links_query(opts \\ []) do
    # STEP 1: Build inner query with GROUP BY
    # This query aggregates data but its computed fields can't be used in WHERE
    inner_query =
      base_query()
      |> filter_link_media_types()
      |> maybe_apply_time_limit(opts)
      |> maybe_exclude_activity_types(opts)
      |> group_by_url()
      |> select_aggregated_fields()

    # STEP 2: Wrap in subquery
    # This converts aggregated fields (share_count, etc.) into regular columns
    # that CAN be used in WHERE clauses for keyset pagination
    from(t in subquery(inner_query),
      as: :trending,
      order_by: ^build_order_by(opts)
    )
  end

  # Base query joins Media -> Files -> Activity
  # Media contains URL metadata, Files links Media to objects, Activity has timestamps
  defp base_query do
    from(media in Media,
      as: :media,
      # Files is a mixin table: id = object_id (e.g., Post), media_id = Media.id
      # INNER JOIN ensures we only get Media that are attached to something
      join: files in Bonfire.Files,
      as: :files,
      on: files.media_id == media.id,
      # Activity tracks who did what to which object
      # object_id matches files.id (the Post/object ID)
      join: activity in Activity,
      as: :activity,
      on: activity.object_id == files.id
    )
  end

  # Filter to only include link preview media (exclude images, avatars, etc.)
  defp filter_link_media_types(query) do
    where(query, [media: m], m.media_type not in ^@exclude_media_types)
  end

  # Group by URL path to aggregate multiple shares of same link
  defp group_by_url(query) do
    group_by(query, [media: m], m.path)
  end

  # Select aggregated fields - these become the columns in our result set
  defp select_aggregated_fields(query) do
    select(query, [media: m, activity: a], %{
      # The URL - this is our grouping key and must be unique per row
      path: m.path,

      # Count of activities (shares) for this URL
      share_count: count(a.id),

      # First media ID - we'll use this to load the Media record for metadata
      first_media_id: min(m.id),

      # Most recent activity - used for chronological sorting cursor
      newest_activity_id: max(a.id),

      # Array of all activity IDs - used to load boost counts
      activity_ids: fragment("array_agg(DISTINCT ?)", a.id),

      # Array of all sharer user IDs - used to load User records
      sharer_ids: fragment("array_agg(DISTINCT ?)", a.subject_id)
    })
  end

  # Build ORDER BY clause based on sort option
  # IMPORTANT: The ORDER BY must use named binding `:trending` which refers
  # to the outer subquery, not the inner query bindings
  defp build_order_by(opts) do
    case Keyword.get(opts, :sort_by) do
      :date_created ->
        # Chronological: most recently shared first
        # Uses newest_activity_id as primary sort, path as tiebreaker
        [
          desc: dynamic([trending: t], t.newest_activity_id),
          desc: dynamic([trending: t], t.path)
        ]

      _ ->
        # Default: popularity (most shares first)
        # Uses share_count as primary sort, path as tiebreaker
        [
          desc: dynamic([trending: t], t.share_count),
          desc: dynamic([trending: t], t.path)
        ]
    end
  end

  # Filter activities within a time window
  defp maybe_apply_time_limit(query, opts) do
    case Keyword.get(opts, :time_limit) do
      nil -> query
      0 -> query  # 0 means no time limit
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)
        where(query, [activity: a], a.inserted_at >= ^cutoff)
    end
  end

  # Exclude certain activity types (e.g., boosts, replies)
  # We typically want only original shares, not boosts of boosts
  defp maybe_exclude_activity_types(query, opts) do
    case Keyword.get(opts, :exclude_activity_types) do
      nil -> query
      [] -> query
      types when is_list(types) ->
        # Convert atoms to strings for database comparison
        type_strings = Enum.map(types, &to_string/1)
        where(query, [activity: a], a.verb not in ^type_strings)
    end
  end
end
```

### Key Design Decisions Explained

1. **Why subquery wrapping?**
   - Keyset pagination needs to filter with `WHERE (share_count, path) < (?, ?)`
   - But `share_count` is a `count()` aggregate which can't be in WHERE
   - Wrapping in subquery makes it a regular column

2. **Why path as tiebreaker?**
   - Must be unique per row (guaranteed by GROUP BY)
   - Provides deterministic ordering when primary sort values are equal

3. **Why INNER JOINs?**
   - We only want Media that is attached to Activities
   - LEFT JOINs would include orphaned Media records

---

## 2. Context Layer (TrendingLinks)

**Purpose**: Provide public API, handle pagination configuration, and hydrate results with related data.

**File location**: `extensions/bonfire_social/lib/trending_links.ex`

```elixir
defmodule Bonfire.Social.TrendingLinks do
  @moduledoc """
  Context module for trending links functionality.

  Provides two main entry points:
  - `list_trending/1` - Simple list for widgets (no pagination)
  - `list_trending_paginated/1` - Full pagination for feeds

  Both functions return hydrated results with Media objects, User profiles,
  and boost counts loaded.
  """

  use Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]
  import Ecto.Query

  alias Bonfire.Social.MediaFeedLoader
  alias Bonfire.Social.Boosts
  alias Bonfire.Files.Media

  # Default configuration - can be overridden via options
  @default_limit 20
  @default_time_limit 7  # days
  @default_exclude_activity_types [:reply, :boost]

  @doc """
  List trending links without pagination.

  Used by widgets that show a fixed number of items.

  ## Options

  - `:limit` - Maximum number of results (default: 20)
  - `:offset` - Number of results to skip (default: 0)
  - `:time_limit` - Days to look back (default: 7)
  - `:sort_by` - `:popularity` or `:date_created`

  ## Examples

      # Get top 5 trending links from past week
      TrendingLinks.list_trending(limit: 5)

      # Get trending links from past month
      TrendingLinks.list_trending(time_limit: 30)
  """
  def list_trending(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    # Merge defaults with provided options
    query_opts = Keyword.merge(
      [
        time_limit: @default_time_limit,
        exclude_activity_types: @default_exclude_activity_types
      ],
      opts
    )

    MediaFeedLoader.trending_links_query(query_opts)
    |> limit(^limit)
    |> offset(^offset)
    |> repo().all()
    |> hydrate_results()
  rescue
    e ->
      error(e, "Error fetching trending links")
      []
  end

  @doc """
  List trending links with keyset pagination.

  Used by FeedLive for full-page feeds with "Load more" functionality.

  ## Options

  Accepts all options from `list_trending/1` plus pagination options:

  - `:paginate` or direct options - Map/keyword with:
    - `:limit` - Page size
    - `:after` - Cursor for next page
    - `:before` - Cursor for previous page
  - `:feed_filters` - Map with filters from UI (time_limit, sort_by)

  ## Returns

      %{
        edges: [%{path: "...", media: %Media{}, sharers: [...], ...}, ...],
        page_info: %{
          has_next_page: boolean,
          has_previous_page: boolean,
          end_cursor: "...",
          start_cursor: "..."
        }
      }

  ## Examples

      # First page
      TrendingLinks.list_trending_paginated(limit: 10)

      # Next page using cursor
      TrendingLinks.list_trending_paginated(limit: 10, after: "cursor_string")

      # With filters from UI
      TrendingLinks.list_trending_paginated(
        paginate: %{limit: 10},
        feed_filters: %{time_limit: 30, sort_by: :date_created}
      )
  """
  def list_trending_paginated(opts \\ []) do
    opts = to_options(opts)

    # Extract sort/filter options - can come from opts directly or nested in feed_filters
    sort_by = opts[:sort_by] || e(opts, :feed_filters, :sort_by, nil)
    sort_order = opts[:sort_order] || :desc
    time_limit = get_time_limit(opts)

    # Build the query with filters
    query = MediaFeedLoader.trending_links_query(
      time_limit: time_limit,
      sort_by: sort_by,
      exclude_activity_types: @default_exclude_activity_types
    )

    # Configure pagination with cursor fields matching our ORDER BY
    paginate_opts = Keyword.merge(
      opts[:paginate] || opts,
      order_pagination_opts(sort_by, sort_order)
    )

    # Execute paginated query
    case repo().many_paginated(query, paginate_opts) do
      %{edges: edges, page_info: page_info} ->
        # Hydrate results and add metadata
        hydrated_edges =
          edges
          |> hydrate_results()
          |> Enum.with_index()
          |> Enum.map(fn {link, index} ->
            link
            # Type tag for polymorphic rendering in feeds
            |> Map.put(:__type__, :trending_link)
            # First item on first page is "featured" (larger card)
            |> Map.put(:featured, index == 0 and is_nil(paginate_opts[:after]))
          end)

        %{edges: hydrated_edges, page_info: page_info}

      error ->
        error
    end
  end

  # Extract time_limit from various possible locations in opts
  defp get_time_limit(opts) do
    case opts[:time_limit] || e(opts, :feed_filters, :time_limit, nil) do
      nil -> @default_time_limit
      val -> val
    end
  end

  # Configure cursor fields for keyset pagination
  # CRITICAL: These must match the ORDER BY in the query exactly
  defp order_pagination_opts(sort_by, sort_order) do
    [
      cursor_fields: order_cursor_fields(sort_by, sort_order),
      fetch_cursor_value_fun: &fetch_cursor_value_fun/2
    ]
  end

  # Define cursor fields based on sort option
  # Each tuple is {field_name, sort_direction}
  defp order_cursor_fields(:date_created, sort_order) do
    [{:newest_activity_id, sort_order}, {:path, sort_order}]
  end

  defp order_cursor_fields(_, sort_order) do
    # Default: popularity sort
    [{:share_count, sort_order}, {:path, sort_order}]
  end

  # Function to extract cursor values from result rows
  # Called by Paginator to build cursor strings
  defp fetch_cursor_value_fun(row, :share_count), do: row[:share_count] || 0
  defp fetch_cursor_value_fun(row, :newest_activity_id), do: row[:newest_activity_id]
  defp fetch_cursor_value_fun(row, :path), do: row[:path]
  defp fetch_cursor_value_fun(row, field), do: Map.get(row, field)

  # ============================================================================
  # HYDRATION
  # ============================================================================
  # Load related data after the main query to avoid N+1 issues.
  # We batch-load all related records in single queries.

  defp hydrate_results(results) when is_list(results) do
    results
    |> load_media_objects()
    |> load_sharers()
    |> load_boost_counts()
  end

  defp hydrate_results(result), do: result

  # Load Media objects for metadata (title, description, thumbnail)
  defp load_media_objects(results) do
    media_ids =
      results
      |> Enum.map(& &1.first_media_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if media_ids == [] do
      results
    else
      media_map =
        from(m in Media, where: m.id in ^media_ids)
        |> repo().all()
        |> Map.new(&{&1.id, &1})

      Enum.map(results, fn result ->
        Map.put(result, :media, Map.get(media_map, result.first_media_id))
      end)
    end
  end

  # Load User profiles for sharers
  defp load_sharers(results) do
    all_sharer_ids =
      results
      |> Enum.flat_map(&(&1.sharer_ids || []))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if all_sharer_ids == [] do
      Enum.map(results, &Map.put(&1, :sharers, []))
    else
      # Load users with their profiles
      users =
        Bonfire.Me.Users.list_by_id(all_sharer_ids)
        |> Map.new(&{&1.id, &1})

      Enum.map(results, fn result ->
        sharers =
          (result.sharer_ids || [])
          |> Enum.map(&Map.get(users, &1))
          |> Enum.reject(&is_nil/1)

        result
        |> Map.put(:sharers, sharers)
        |> Map.put(:unique_sharers, length(sharers))
      end)
    end
  end

  # Load boost counts for each link
  defp load_boost_counts(results) do
    all_activity_ids =
      results
      |> Enum.flat_map(&(&1.activity_ids || []))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if all_activity_ids == [] do
      Enum.map(results, &Map.put(&1, :total_boosts, 0))
    else
      # Get boost counts grouped by activity
      boost_counts = Boosts.count_by_object_ids(all_activity_ids)

      Enum.map(results, fn result ->
        total =
          (result.activity_ids || [])
          |> Enum.map(&Map.get(boost_counts, &1, 0))
          |> Enum.sum()

        Map.put(result, :total_boosts, total)
      end)
    end
  end
end
```

### Key Design Decisions Explained

1. **Two entry points (list_trending vs list_trending_paginated)**
   - Widgets need simple lists with limit/offset
   - Feeds need cursor-based pagination with page_info
   - Sharing hydration logic between both

2. **Keyset pagination cursor fields**
   - Must exactly match ORDER BY clause
   - Include tiebreaker field (path) for deterministic ordering
   - `fetch_cursor_value_fun` extracts values from result maps

3. **Hydration as separate step**
   - Main query returns IDs/arrays
   - Batch-load related records in single queries
   - Avoids N+1 query problems

4. **Type tagging with `__type__`**
   - Enables polymorphic rendering in feeds
   - FeedLive uses this to select the right card component

---

## 3. Widget Component

**Purpose**: Compact component for sidebar display, showing a small number of items.

**Files**:
- `extensions/bonfire_ui_social/lib/components/widgets/widget_trending_links_live.ex`
- `extensions/bonfire_ui_social/lib/components/widgets/widget_trending_links_live.sface`

### Module Definition

```elixir
defmodule Bonfire.UI.Social.WidgetTrendingLinksLive do
  @moduledoc """
  Sidebar widget showing trending links.

  Displays a compact list of trending links with basic metadata.
  Uses lazy loading to avoid blocking initial page render.
  """

  use Bonfire.UI.Common.Web, :stateful_component

  alias Bonfire.Social.TrendingLinks

  # Props that can be passed when mounting the widget
  prop widget_title, :string, default: nil
  prop limit, :integer, default: 5

  @doc """
  Called on mount and updates.

  Uses `connected?/1` to defer data loading until WebSocket is established.
  This ensures fast initial page loads.
  """
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Only fetch data after WebSocket connects (not during static render)
    links =
      if connected?(socket) do
        TrendingLinks.list_trending(limit: socket.assigns.limit)
      else
        []
      end

    {:ok,
     assign(socket,
       links: links,
       loaded: connected?(socket)
     )}
  end
end
```

### Template

```html
{!-- widget_trending_links_live.sface --}

<Bonfire.UI.Common.WidgetBlockLive
  widget_title={@widget_title || l("Trending Links")}
>
  {#if @loaded and @links != []}
    <ul class="flex flex-col">
      {#for link <- @links}
        <li class="border-b border-base-content/10 last:border-0">
          <a
            href={link.path}
            target="_blank"
            rel="noopener"
            class="flex flex-col gap-1 p-3 hover:bg-base-content/5"
          >
            {!-- Link title from metadata, fallback to URL --}
            <span class="font-medium text-sm line-clamp-2">
              {e(link, :media, :metadata, "name", nil) || link.path}
            </span>

            {!-- Share count --}
            <span class="text-xs text-base-content/60">
              {link.share_count} {lp("share", "shares", link.share_count)}
            </span>
          </a>
        </li>
      {/for}
    </ul>

    {!-- Link to full feed --}
    <div class="p-3 border-t border-base-content/10">
      <LinkLive to={~p"/trending/links"} class="link link-primary text-sm">
        {l("View all trending links")}
      </LinkLive>
    </div>

  {#elseif @loaded}
    <div class="p-4 text-center text-base-content/60 text-sm">
      {l("No trending links yet")}
    </div>

  {#else}
    {!-- Loading state --}
    <div class="p-4 flex justify-center">
      <span class="loading loading-spinner loading-sm" />
    </div>
  {/if}
</Bonfire.UI.Common.WidgetBlockLive>
```

### Key Patterns

1. **Lazy loading with `connected?/1`**
   - Returns `false` during initial static render
   - Returns `true` after WebSocket connects
   - Data is fetched only after connection, keeping initial load fast

2. **WidgetBlockLive wrapper**
   - Provides consistent widget styling
   - Handles title, collapse state, etc.

3. **Loading states**
   - Show spinner while loading
   - Show empty state message when no data
   - Show content when data available

---

## 4. Feed Card Component

**Purpose**: Render individual items in the full-page feed with detailed information.

**Files**:
- `extensions/bonfire_ui_social/lib/components/feeds/trending_link_card_live.ex`
- `extensions/bonfire_ui_social/lib/components/feeds/trending_link_card_live.sface`

### Module Definition

```elixir
defmodule Bonfire.UI.Social.TrendingLinkCardLive do
  @moduledoc """
  Renders a trending link card with metadata, sharers, and engagement counts.

  Has two display modes:
  - `featured: true` - Large card with thumbnail for first item
  - `featured: false` - Compact card for subsequent items
  """

  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Common.URIs

  # Required: the link data from TrendingLinks.list_trending_paginated
  prop link, :map, required: true

  # Optional styling
  prop class, :css_class, default: nil
  prop show_thumbnail, :boolean, default: false
  prop featured, :boolean, default: false
end
```

### Template

```html
{!-- trending_link_card_live.sface --}

{#if @featured}
  {!-- FEATURED CARD: Large layout with thumbnail --}
  <article class={"card bg-base-100 border border-base-content/10 overflow-hidden", @class}>
    {!-- Thumbnail if available --}
    {#if @show_thumbnail or @featured}
      {#if image_url = e(@link, :media, :metadata, "image", nil)}
        <figure class="aspect-video bg-base-200">
          <img src={image_url} alt="" class="w-full h-full object-cover" loading="lazy" />
        </figure>
      {/if}
    {/if}

    <div class="card-body gap-2">
      {!-- Provider/domain --}
      <div class="text-xs text-base-content/60 uppercase tracking-wide">
        {URIs.display_hostname(@link.path)}
      </div>

      {!-- Title --}
      <h3 class="card-title text-lg">
        <a href={@link.path} target="_blank" rel="noopener" class="hover:underline">
          {e(@link, :media, :metadata, "name", nil) || @link.path}
        </a>
      </h3>

      {!-- Description --}
      {#if description = e(@link, :media, :metadata, "summary", nil)}
        <p class="text-sm text-base-content/80 line-clamp-2">{description}</p>
      {/if}

      {!-- Engagement stats --}
      <div class="flex items-center gap-4 mt-2 text-sm text-base-content/60">
        {!-- Sharers avatars --}
        <div class="flex items-center gap-2">
          <div class="avatar-group -space-x-3">
            {#for sharer <- Enum.take(@link.sharers || [], 3)}
              <Bonfire.UI.Common.AvatarLive
                user={sharer}
                class="w-6 h-6"
              />
            {/for}
          </div>
          <span>{@link.share_count} {lp("share", "shares", @link.share_count)}</span>
        </div>

        {!-- Boost count --}
        {#if @link.total_boosts > 0}
          <div class="flex items-center gap-1">
            <#Icon iconify="ph:rocket-fill" class="w-4 h-4" />
            <span>{@link.total_boosts}</span>
          </div>
        {/if}
      </div>
    </div>
  </article>

{#else}
  {!-- COMPACT CARD: Smaller layout for list view --}
  <article class={"flex gap-3 p-3 border-b border-base-content/10", @class}>
    {!-- Small thumbnail --}
    {#if @show_thumbnail}
      {#if image_url = e(@link, :media, :metadata, "image", nil)}
        <figure class="w-20 h-20 flex-shrink-0 rounded bg-base-200 overflow-hidden">
          <img src={image_url} alt="" class="w-full h-full object-cover" loading="lazy" />
        </figure>
      {/if}
    {/if}

    <div class="flex-1 min-w-0">
      {!-- Provider --}
      <div class="text-xs text-base-content/60">
        {URIs.display_hostname(@link.path)}
      </div>

      {!-- Title --}
      <h3 class="font-medium line-clamp-2">
        <a href={@link.path} target="_blank" rel="noopener" class="hover:underline">
          {e(@link, :media, :metadata, "name", nil) || @link.path}
        </a>
      </h3>

      {!-- Stats --}
      <div class="flex items-center gap-3 mt-1 text-xs text-base-content/60">
        <span>{@link.share_count} {lp("share", "shares", @link.share_count)}</span>
        {#if @link.total_boosts > 0}
          <span class="flex items-center gap-1">
            <#Icon iconify="ph:rocket-fill" class="w-3 h-3" />
            {@link.total_boosts}
          </span>
        {/if}
      </div>
    </div>
  </article>
{/if}
```

---

## 5. Feed Integration

To integrate your aggregated data with Bonfire's feed system:

### 5.1 Create Feed LiveHandler

**File**: `extensions/bonfire_ui_social/lib/components/feeds/trending_links_live_handler.ex`

```elixir
defmodule Bonfire.UI.Social.TrendingLinksLiveHandler do
  @moduledoc """
  LiveView event handlers for trending links feed.
  """

  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Social.TrendingLinks

  @doc """
  Load initial feed data.
  Called by FeedLive when feed_name is :trending_links.
  """
  def handle_event("load_feed", params, socket) do
    result = TrendingLinks.list_trending_paginated(
      paginate: %{limit: params["limit"] || 20},
      feed_filters: socket.assigns[:feed_filters] || %{}
    )

    {:noreply,
     socket
     |> assign(:feed, result.edges)
     |> assign(:page_info, result.page_info)
     |> assign(:loading, false)}
  end

  @doc """
  Load next page of results.
  """
  def handle_event("load_more", %{"after" => cursor}, socket) do
    result = TrendingLinks.list_trending_paginated(
      paginate: %{
        limit: 20,
        after: cursor
      },
      feed_filters: socket.assigns[:feed_filters] || %{}
    )

    {:noreply,
     socket
     |> update(:feed, &(&1 ++ result.edges))
     |> assign(:page_info, result.page_info)}
  end
end
```

### 5.2 Register Feed Type

The feed system needs to know how to load your feed type. This is typically done in the feeds configuration.

### 5.3 Add Route

**File**: `extensions/bonfire_ui_social/lib/web/routes.ex`

```elixir
scope "/", Bonfire.UI.Social do
  pipe_through(:browser)

  live "/trending/links", FeedsLive, :trending_links
end
```

---

## 6. Dashboard Integration

To add widgets to the dashboard main content area:

### 6.1 Update Dashboard Mount

**File**: `extensions/social/priv/templates/lib/bonfire/web/views/dashboard_live.ex`

```elixir
def mount(_params, _session, socket) do
  current_user = current_user(socket)

  # ... existing sidebar_widgets setup ...

  # Main content widgets for dashboard (when no specific feed is selected)
  # These are displayed in the main content area, not the sidebar
  main_widgets =
    Enum.filter(
      [
        # Trending Links widget with custom options
        {Bonfire.UI.Social.WidgetTrendingLinksLive,
         [limit: 5, widget_title: l("Trending Links")]},

        # Add more widgets here as needed:
        # {Bonfire.UI.Social.WidgetDiscussionsLive, []},
        # {Bonfire.Tag.Web.WidgetTagsLive, [limit: 10]},
      ],
      & &1  # Filter out nil entries
    )

  {:ok,
   socket
   |> assign(
     # ... existing assigns ...
     main_widgets: main_widgets
   )}
end
```

### 6.2 Update Dashboard Template

**File**: `extensions/social/priv/templates/lib/bonfire/web/views/dashboard_live.sface`

```html
{#case @default_feed}
  {#match :curated}
    {!-- Curated feed --}
    <StatefulComponent module={...} />

  {#match feed when feed in [:my, true]}
    {!-- My Following feed --}
    <StatefulComponent module={...} />

  {#match _}
    {!-- Default: Show widgets --}
    {#case @main_widgets
      |> Enum.map(fn
        {component, component_assigns} ->
          %{
            module: component,
            data: component_assigns,
            type: Surface.Component
          }
        %{} = widget ->
          widget
        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)}

      {#match widgets when is_list(widgets) and widgets != []}
        <Bonfire.UI.Common.WidgetsLive
          widgets={widgets}
          page={@page}
          selected_tab={@selected_tab}
          showing_within={:main}
          container_class="flex flex-col gap-4"
          id="dashboard_main_widgets"
          with_title
        />

      {#match _}
        {!-- Fallback: Show configuration prompt --}
        <div class="border border-primary/30 border-dashed rounded-xl p-4 m-4 text-center">
          <div>{l "You can customise your dashboard by adding widgets here."}</div>
          <LinkLive to={~p"/settings/user/dashboard"} class="link link-primary">
            {l "Configure"}
          </LinkLive>
        </div>
    {/case}
{/case}
```

### Widget Format

Widgets use tuple format `{Module, props}` which gets transformed to:

```elixir
%{
  module: Module,
  data: props,  # Keyword list of props
  type: Surface.Component
}
```

The `WidgetsLive` component handles rendering each widget with consistent styling.

---

## 7. Testing

**File**: `extensions/bonfire_social/test/trending/trending_links_test.exs`

```elixir
defmodule Bonfire.Social.TrendingLinksTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.TrendingLinks
  alias Bonfire.Social.Boosts
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake
  import Tesla.Mock

  # Mock external URL fetches for link metadata
  defp setup_url_mocks do
    mock(fn
      %{method: :get, url: "https://example.com/" <> _} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Test Article</title></head></html>"
        }
    end)
  end

  describe "list_trending/1" do
    setup do
      setup_url_mocks()

      user1 = Fake.fake_user!()
      user2 = Fake.fake_user!()

      # Create posts with links
      post1 = fake_post!(user1, "public", %{
        post_content: %{html_body: "Check this https://example.com/article1"}
      })
      post2 = fake_post!(user2, "public", %{
        post_content: %{html_body: "Also interesting https://example.com/article1"}
      })

      # Add boosts
      {:ok, _} = Boosts.boost(user2, post1)

      %{users: [user1, user2], posts: [post1, post2]}
    end

    test "returns trending links with correct structure" do
      results = TrendingLinks.list_trending()

      assert is_list(results)
      assert length(results) > 0

      first = List.first(results)
      assert Map.has_key?(first, :path)
      assert Map.has_key?(first, :media)
      assert Map.has_key?(first, :share_count)
      assert Map.has_key?(first, :sharers)
      assert Map.has_key?(first, :total_boosts)

      assert is_binary(first.path)
      assert is_integer(first.share_count)
      assert is_list(first.sharers)
    end

    test "groups same URL shared by multiple users" do
      results = TrendingLinks.list_trending()

      article1_entries = Enum.filter(results, &String.contains?(&1.path, "article1"))
      # Same URL should be grouped into one entry
      assert length(article1_entries) == 1
    end

    test "counts shares correctly" do
      results = TrendingLinks.list_trending()

      article1 = Enum.find(results, &String.contains?(&1.path, "article1"))
      # Two users shared this URL
      assert article1.share_count == 2
    end

    test "respects limit option" do
      results = TrendingLinks.list_trending(limit: 1)
      assert length(results) <= 1
    end

    test "respects time_limit option" do
      # Create old post
      user = Fake.fake_user!()
      old_post = fake_post!(user, "public", %{
        post_content: %{html_body: "Old https://example.com/old"},
        id: DatesTimes.past(10, :day) |> DatesTimes.generate_ulid()
      })

      # Default 7-day window should exclude old post
      results = TrendingLinks.list_trending(time_limit: 7)
      old_links = Enum.filter(results, &String.contains?(&1.path, "old"))
      assert length(old_links) == 0

      # 30-day window should include old post
      results = TrendingLinks.list_trending(time_limit: 30)
      old_links = Enum.filter(results, &String.contains?(&1.path, "old"))
      assert length(old_links) > 0
    end
  end

  describe "list_trending_paginated/1" do
    setup do
      setup_url_mocks()

      user = Fake.fake_user!()

      # Create multiple links
      Enum.each(1..15, fn i ->
        post = fake_post!(user, "public", %{
          post_content: %{html_body: "Link https://example.com/article#{i}"}
        })
        {:ok, _} = Boosts.boost(user, post)
      end)

      %{user: user}
    end

    test "returns paginated results with page_info" do
      result = TrendingLinks.list_trending_paginated(limit: 5)

      assert Map.has_key?(result, :edges)
      assert Map.has_key?(result, :page_info)
      assert length(result.edges) <= 5
    end

    test "supports cursor-based pagination" do
      # Get first page
      page1 = TrendingLinks.list_trending_paginated(limit: 5)
      assert length(page1.edges) == 5
      assert page1.page_info.has_next_page

      # Get second page using cursor
      page2 = TrendingLinks.list_trending_paginated(
        limit: 5,
        after: page1.page_info.end_cursor
      )
      assert length(page2.edges) > 0

      # Pages should have different items
      page1_paths = Enum.map(page1.edges, & &1.path)
      page2_paths = Enum.map(page2.edges, & &1.path)
      assert Enum.all?(page2_paths, &(&1 not in page1_paths))
    end

    test "marks first item as featured on first page only" do
      page1 = TrendingLinks.list_trending_paginated(limit: 5)
      page2 = TrendingLinks.list_trending_paginated(
        limit: 5,
        after: page1.page_info.end_cursor
      )

      # First item on first page is featured
      assert List.first(page1.edges).featured == true
      # Other items are not featured
      assert Enum.all?(Enum.drop(page1.edges, 1), &(&1.featured == false))
      # Items on subsequent pages are not featured
      assert Enum.all?(page2.edges, &(&1.featured == false))
    end

    test "adds __type__ for polymorphic rendering" do
      result = TrendingLinks.list_trending_paginated(limit: 5)
      assert Enum.all?(result.edges, &(&1.__type__ == :trending_link))
    end
  end
end
```

---

## 8. Complete File Listing

| Layer | File | Purpose |
|-------|------|---------|
| Query | `extensions/bonfire_social/lib/media_feed_loader.ex` | Ecto query builder with GROUP BY |
| Context | `extensions/bonfire_social/lib/trending_links.ex` | Public API, pagination, hydration |
| Widget | `extensions/bonfire_ui_social/lib/components/widgets/widget_trending_links_live.ex` | Sidebar widget component |
| Widget | `extensions/bonfire_ui_social/lib/components/widgets/widget_trending_links_live.sface` | Widget template |
| Card | `extensions/bonfire_ui_social/lib/components/feeds/trending_link_card_live.ex` | Feed item card component |
| Card | `extensions/bonfire_ui_social/lib/components/feeds/trending_link_card_live.sface` | Card template |
| Dashboard | `extensions/social/priv/templates/lib/bonfire/web/views/dashboard_live.ex` | Dashboard LiveView |
| Dashboard | `extensions/social/priv/templates/lib/bonfire/web/views/dashboard_live.sface` | Dashboard template |
| Test | `extensions/bonfire_social/test/trending/trending_links_test.exs` | Test suite |

---

## 9. Implementation Checklist

Use this checklist when implementing a new aggregated feed feature:

### Query Layer
- [ ] Create query module in `extensions/bonfire_social/lib/`
- [ ] Define base query with necessary JOINs
- [ ] Implement GROUP BY clause for aggregation
- [ ] Add `select` with aggregated fields (count, array_agg, etc.)
- [ ] Wrap in subquery for keyset pagination compatibility
- [ ] Implement configurable ORDER BY
- [ ] Add time limit filtering
- [ ] Add exclusion filtering (activity types, etc.)

### Context Layer
- [ ] Create context module in `extensions/bonfire_social/lib/`
- [ ] Implement `list_*/1` for simple widget use
- [ ] Implement `list_*_paginated/1` for feed use
- [ ] Configure cursor fields matching ORDER BY
- [ ] Implement `fetch_cursor_value_fun/2`
- [ ] Implement hydration functions for related data
- [ ] Add `__type__` tag for polymorphic rendering
- [ ] Add `featured` flag for first item

### Widget Component
- [ ] Create stateful component in `extensions/bonfire_ui_social/lib/components/widgets/`
- [ ] Define props (limit, title, etc.)
- [ ] Implement lazy loading with `connected?/1`
- [ ] Create template with loading/empty/content states
- [ ] Use WidgetBlockLive wrapper

### Card Component
- [ ] Create stateless component in `extensions/bonfire_ui_social/lib/components/feeds/`
- [ ] Define props (link, featured, class)
- [ ] Create featured variant (large, with thumbnail)
- [ ] Create compact variant (small, list item)
- [ ] Display metadata, engagement stats, sharers

### Feed Integration
- [ ] Create LiveHandler for event handling
- [ ] Register feed type in configuration
- [ ] Add route in routes.ex
- [ ] Configure polymorphic rendering in FeedLive

### Dashboard Integration
- [ ] Add widget to `main_widgets` in dashboard mount
- [ ] Update dashboard template to use WidgetsLive
- [ ] Test widget displays correctly

### Testing
- [ ] Create test file in `extensions/bonfire_social/test/`
- [ ] Mock external dependencies (URLs, etc.)
- [ ] Test structure of returned data
- [ ] Test aggregation logic
- [ ] Test filtering (time limit, exclusions)
- [ ] Test pagination (page_info, cursors)
- [ ] Test featured/type tagging

---

## Appendix: Common Patterns

### A. Extracting Filter Values from Multiple Sources

Options can come from direct parameters or nested in `feed_filters`:

```elixir
def get_filter(opts, key, default) do
  opts[key] || e(opts, :feed_filters, key, nil) || default
end
```

### B. Defensive Hydration

Handle empty ID lists to avoid unnecessary queries:

```elixir
defp load_related(results, id_key, load_fn) do
  ids = results |> Enum.map(&Map.get(&1, id_key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  if ids == [] do
    results
  else
    # ... batch load
  end
end
```

### C. Module Attribute for Repeated Values

```elixir
@default_exclude_activity_types [:reply, :boost]

# Use in multiple places
def list_trending(opts), do: query(exclude_activity_types: @default_exclude_activity_types, ...)
def list_trending_paginated(opts), do: query(exclude_activity_types: @default_exclude_activity_types, ...)
```
