defmodule Bonfire.Social.Events do
  @moduledoc """
  Context for event objects (ActivityStreams `Event`, e.g. federated from Mobilizon/Gancio).

  Owns the event feed entry point and the pure ActivityStreams accessors/parsers shared by the UI (the `/events` page, the agenda preview, and the full event card). Display concerns (labels, icons, colours, formatting) stay in the UI layer; the FEP-8a8e category vocabulary lives in `Bonfire.Social.Events.Categories`.

  Events are backed by `Bonfire.Data.Social.APActivity` rows whose `json` column holds the AS2 `Event`. The `:events` feed preset (see `runtime_config.ex`) and its "Events Feed" preload rule already SQL-load that object (incl. `json`) and the subject, so callers should go through `feed/1` rather than querying `APActivity` directly.
  """
  use Bonfire.Common.Utils
  import Ecto.Query, only: [from: 2]

  alias Bonfire.Data.Social.APActivity

  @doc """
  The `:events` feed, paginated, with each activity's `APActivity` object (carrying the AS2 `json`) attached.

  The feed itself is loaded with a light `:with_subject` preload (so the event host shows) — the richer object preloads (`:with_object_more` et al.) inner-join the object's typed sub-tables and silently drop `APActivity` events from the results, so instead we batch-load the `APActivity` rows here and attach them onto each `activity.object`. Keeping this query in the context (rather than the UI view) is why the view stays query-free.

  Accepts the usual feed opts (`current_user:`, `paginate:`, …). Pass `categories:` (a list of FEP-8a8e category keys) to filter to those categories.
  """
  def feed(opts) do
    {categories, opts} = Keyword.pop(opts, :categories)

    filters =
      case List.wrap(categories) do
        [] -> %{feed_name: :events}
        cats -> %{feed_name: :events, object_categories: cats}
      end

    opts = Keyword.put_new(opts, :preload, [:with_subject])

    case Bonfire.Social.FeedActivities.feed(filters, opts) do
      %{edges: edges} = result when is_list(edges) ->
        %{result | edges: attach_objects(edges)}

      other ->
        other
    end
  end

  # Batch-load the `APActivity` rows (which carry the AS2 `json`) and set each onto its `activity.object` (the feed only resolves it to a bare Needle pointer).
  defp attach_objects(edges) do
    objects = load_objects(edges)

    Enum.map(edges, fn edge ->
      with %{} = object <- Map.get(objects, e(edge, :activity, :object_id, nil)),
           activity when not is_nil(activity) <- e(edge, :activity, nil) do
        Map.put(edge, :activity, Map.put(activity, :object, object))
      else
        _ -> edge
      end
    end)
  end

  defp load_objects(edges) do
    ids =
      edges
      |> Enum.map(&e(&1, :activity, :object_id, nil))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(a in APActivity, where: a.id in ^ids)
      |> Bonfire.Common.Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  A field from an AS2 `Event` map, handling both the nested `object` shape and the flat shape.

  ## Examples

      iex> object_field(%{"name" => "Flat"}, "name")
      "Flat"

      iex> object_field(%{"object" => %{"name" => "Nested"}}, "name")
      "Nested"

      iex> object_field(nil, "name")
      nil
  """
  def object_field(json, field) when is_map(json) do
    e(json, "object", field, nil) || e(json, field, nil)
  end

  def object_field(_, _), do: nil

  @doc """
  The event's title (`name`), or nil.

  ## Examples

      iex> title(%{"name" => "Launch Party"})
      "Launch Party"

      iex> title(%{})
      nil
  """
  def title(json), do: object_field(json, "name")

  @doc """
  Parse an ISO8601 event time into the data the UI needs.

  Restores the event's *original* local wall-clock time (federated events carry their own timezone), so a 17:00 event reads as 17:00 regardless of the viewer's zone, and keeps the raw ISO string for a machine-readable `<time datetime=…>`. Returns `%{iso: binary, local: DateTime.t(), offset: integer}` or `nil`.

  ## Examples

      iex> parse_time("2026-06-08T13:00:00+02:00")
      %{iso: "2026-06-08T13:00:00+02:00", local: ~U[2026-06-08 13:00:00Z], offset: 7200}

      iex> parse_time("not a date")
      nil

      iex> parse_time(nil)
      nil
  """
  def parse_time(iso) when is_binary(iso) do
    with {:ok, datetime, offset} <- DateTime.from_iso8601(iso) do
      %{iso: iso, local: DateTime.add(datetime, offset, :second), offset: offset}
    else
      _ -> nil
    end
  end

  def parse_time(_), do: nil

  @doc """
  Parsed start time of an event (see `parse_time/1`), or nil.

  ## Examples

      iex> start_time(%{"startTime" => "2026-06-08T13:00:00Z"}).local
      ~U[2026-06-08 13:00:00Z]

      iex> start_time(%{})
      nil
  """
  def start_time(json), do: json |> object_field("startTime") |> parse_time()

  @doc """
  Parsed end time of an event, or nil when there's no end or it's marked hidden (`displayEndTime == "false"`).

  ## Examples

      iex> end_time(%{"endTime" => "2026-06-08T15:00:00Z"}).local
      ~U[2026-06-08 15:00:00Z]

      iex> end_time(%{"endTime" => "2026-06-08T15:00:00Z", "displayEndTime" => "false"})
      nil

      iex> end_time(%{})
      nil
  """
  def end_time(json) do
    if object_field(json, "displayEndTime") != "false" do
      json |> object_field("endTime") |> parse_time()
    end
  end

  @doc """
  A concise location string for an event (venue name, else street address, else locality), or nil.

  ## Examples

      iex> location_name(%{"location" => %{"name" => "The Barn"}})
      "The Barn"

      iex> location_name(%{"location" => %{"address" => %{"addressLocality" => "Berlin"}}})
      "Berlin"

      iex> location_name(%{})
      nil
  """
  def location_name(json) do
    case object_field(json, "location") do
      %{"name" => name} when is_binary(name) and name != "" ->
        name

      %{"address" => %{"streetAddress" => addr}} when is_binary(addr) and addr != "" ->
        addr

      %{"address" => %{"addressLocality" => locality}}
      when is_binary(locality) and locality != "" ->
        locality

      _ ->
        nil
    end
  end

  @doc """
  URL of the first image attachment to use as the event poster, or nil.

  ## Examples

      iex> poster_url(%{"attachment" => [%{"type" => "Document", "mediaType" => "image/png", "url" => "https://example.org/p.png"}]})
      "https://example.org/p.png"

      iex> poster_url(%{})
      nil
  """
  def poster_url(json) do
    case object_field(json, "attachment") do
      attachments when is_list(attachments) ->
        attachments
        |> Enum.find(fn a ->
          e(a, "type", nil) == "Document" and
            String.starts_with?(to_string(e(a, "mediaType", "")), "image/")
        end)
        |> case do
          nil ->
            nil

          attachment ->
            e(attachment, "url", 0, "href", nil) || e(attachment, "url", "href", nil) ||
              e(attachment, "url", nil)
        end

      _ ->
        nil
    end
  end

  @doc """
  Host of a source URL, for the read-only "View on …" link (e.g. `"gancio.cisti.org"`), or nil.

  ## Examples

      iex> source_host("https://gancio.cisti.org/event/42")
      "gancio.cisti.org"

      iex> source_host(nil)
      nil
  """
  def source_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  def source_host(_), do: nil
end
