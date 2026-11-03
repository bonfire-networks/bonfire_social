defmodule Bonfire.Social.RestrictedContent do
  @moduledoc """
  What someone who may find an object but not read it (the `discover` role: `:see` without `:read`) is shown of it, wherever it is shown: its name and summary, and of its media only the one flagged as its primary image (a cover), never its body or other media, whatever its type; and why the rest isn't shown. The web's card (`Bonfire.UI.Social.RestrictedContentLive`) and the API's statuses (`Bonfire.API.MastoCompat.Mappers.Status`) both take it from here, so neither shows more than the other.

  The wording is the instance's (Settings > Instance > Restricted content screen), stored under the card's module as it has been.
  """
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  # the key its settings have always been stored under (the instance settings form, stored instance settings, flavour config like Jacobin's), kept so none of them break
  # TODO: move to a key of this module's own, reading the old one as a fallback, with a `DataMigration` copying stored instance values and the form writing the new key (decided to do separately, 2 November)
  @settings_key Bonfire.UI.Social.RestrictedContentLive

  @doc "What may be shown of `object` (in `activity`) to someone who may not read it: `%{name:, summary:, primary_image:}`, each `nil` when it has none."
  def preview(activity, object) do
    %{
      name: e(object, :post_content, :name, nil) || e(object, :name, nil),
      summary: e(object, :post_content, :summary, nil) || e(object, :summary, nil),
      primary_image: primary_image(activity, object)
    }
  end

  # of its media, only the one flagged as its primary image (a cover), whatever its type
  defp primary_image(activity, object) do
    (e(activity, :files, nil) || e(object, :files, nil) || e(activity, :media, nil) ||
       e(object, :media, nil))
    |> Bonfire.Files.split_primary_image()
    |> elem(0)
  end

  @doc """
  The objects, of these ids, `current_user` may see but not read: what the API shows as the web's closed card. One query for them all, as the web loads a page's boundaries (`Bonfire.Boundaries.boundaries_on_objects/2`).
  """
  def unreadable_ids(object_ids, current_user) do
    case Enums.filter_empty(object_ids, []) do
      [] ->
        MapSet.new()

      ids ->
        boundaries = Bonfire.Boundaries.boundaries_on_objects(ids, current_user)

        ids
        |> Enum.reject(&(Bonfire.Boundaries.can?(current_user, :read, boundaries[&1]) == true))
        |> MapSet.new()
    end
  end

  @doc """
  The feed `items` (activities, or edges holding one as `:activity`) as `current_user` may be shown them: each whose object they may not read keeps its author, date and link, and its content is what the web's card shows (`preview/2`, with `why_not_shown/2` and the instance's `call_to_action/1` as its body), with its cover as its only media. Every API reads its feeds through this, so neither the GraphQL API nor the Mastodon one built on it shows more than the web.
  """
  def redact_unreadable(items, current_user) when is_list(items) do
    unreadable =
      items
      |> Enum.map(&(&1 |> activity_of() |> e(:object_id, nil)))
      |> unreadable_ids(current_user)

    if Enum.empty?(unreadable) do
      items
    else
      Enum.map(items, fn item ->
        activity = activity_of(item)

        if MapSet.member?(unreadable, e(activity, :object_id, nil)),
          do: put_activity(item, redact(activity)),
          else: item
      end)
    end
  end

  def redact_unreadable(items, _current_user), do: items

  defp activity_of(%{activity: %{} = activity}), do: activity
  defp activity_of(activity), do: activity

  defp put_activity(%{activity: %{}} = item, activity), do: %{item | activity: activity}
  defp put_activity(_item, activity), do: activity

  # what may be shown of it, in place of what it holds: its name and summary, why the rest isn't shown as its body, and its cover as its only media
  defp redact(activity) do
    activity = repo().maybe_preload(activity, object: [tree: [parent: [:profile]]])
    object = e(activity, :object, nil)
    preview = preview(activity, object)
    cta = call_to_action()

    body =
      [why_not_shown(e(object, :tree, :parent, nil)), cta && "[#{cta.label}](#{cta.url})"]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join("\n\n")

    post_content = %Bonfire.Data.Social.PostContent{
      id: e(object, :id, nil),
      name: preview.name,
      summary: preview.summary,
      html_body: body
    }

    media = List.wrap(preview.primary_image)

    object =
      if is_map(object),
        do:
          object
          |> put_existing(:post_content, post_content)
          |> put_existing(:media, media)
          |> put_existing(:files, media),
        else: object

    activity
    |> put_existing(:object, object)
    |> put_existing(:object_post_content, post_content)
    |> put_existing(:media, media)
    |> put_existing(:files, media)
    # said in the API (the activity's `restricted` field), so a client can show it as the web's closed card, and the Mastodon adapter leaves its mentions and tags out without asking again. The struct has no field for it, so in memory only
    |> Map.put(:restricted, true)
  end

  @doc "Whether this activity was redacted by `redact_unreadable/2` (its viewer may not read its object)."
  def restricted?(activity), do: Map.get(activity, :restricted) == true

  # only a field the struct has, so it stays a valid one
  defp put_existing(map, key, value),
    do: if(Map.has_key?(map, key), do: Map.put(map, key, value), else: map)

  @doc """
  Why it isn't shown: the instance's configured title when it has enabled its restricted content screen (eg. "Upgrade to read"), else the group that keeps it to its members, else plainly. No noun for the object, which is shown around it, and whose gender would change the sentence in many languages.
  """
  def why_not_shown(published_in, context \\ nil) do
    (enabled?(context) && setting(:title, nil, context)) ||
      case e(published_in, :profile, :name, nil) do
        nil -> l("You can't read this")
        group -> l("Only members of %{group} can read this", group: group)
      end
  end

  @doc """
  Whether the instance shows its full restricted content screen instead of the standard permission error. Opt-in: only an explicit `modularity: true` (or `:enabled`) turns it on, unset means off, unlike the usual modularity semantics. A boot-time default would be clobbered by, or clobber, flavour config, so no default is written anywhere.
  """
  def enabled?(context \\ nil) do
    Settings.get([@settings_key, :modularity], nil, instance_scope(context))
    |> Bonfire.Common.Extend.enabled_value?()
  end

  @doc "The instance's call to action, when it has enabled its restricted content screen and set a link: `%{label:, url:}`, else `nil`."
  def call_to_action(context \\ nil) do
    with true <- enabled?(context),
         url when is_binary(url) <- setting(:cta_url, nil, context) do
      %{label: setting(:cta_label, l("Find out more"), context), url: url}
    else
      _ -> nil
    end
  end

  @doc "One of the configured copy fields, treating unset or empty as `default`"
  def setting(key, default, context \\ nil) do
    Settings.get([@settings_key, key], nil, instance_scope(context))
    |> e(default)
  end

  defp instance_scope(context), do: e(context, :instance_settings, nil) || [scope: :instance]
end
