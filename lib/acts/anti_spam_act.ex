defmodule Bonfire.Social.Acts.AntiSpam do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that marks the sensitivity level of a object (eg. post) or changeset.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `current_user` - self explanatory
  """

  # alias Bonfire.Data.Social.Sensitive
  alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  use Bonfire.Common.Utils
  alias Bonfire.Social.Objects
  alias Ecto.Changeset
  # alias Needle.Changesets
  import Epics
  import Untangle
  use Bonfire.Common.E
  use Arrows
  # alias Bonfire.Common
  # alias Common.Types

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    mode = Keyword.get(act.options, :mode, :halt)
    object = epic.assigns[on]
    current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "Skipping due to `on` option")
        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "Skipping due to missing current_user")
        epic

      not is_struct(object) ->
        warn(object, "Skipping :#{on} due to missing changeset or object (eg. Post)")
        epic

      true ->
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})

        #  :halt
        if mode == :flag do
          if spam?(object, attrs, epic.assigns[:options][:context] || epic.assigns[:options]) do
            with {:error, _} <-
                   Bonfire.Social.Flags.flag(
                     maybe_apply(Bonfire.Me.Users, :get_or_create_automod, [],
                       fallback_return: nil
                     ) || current_user,
                     object
                   ) do
              error("could not flag for mods to check")
              raise Bonfire.Fail, :spam
            else
              _ ->
                debug("flagged for mods to check")
                nil
            end
          end
        else
          check!(object, attrs, epic.assigns[:options][:context] || epic.assigns[:options])
        end || epic

        epic
    end
  end

  def check!(changeset, attrs, context) do
    if spam?(changeset, attrs, context) do
      raise Bonfire.Fail, :spam
    end
  end

  def spam?(changeset, attrs, context) do
    :spam ==
      all_text_content(attrs, changeset)
      |> Bonfire.Common.AntiSpam.service().check_comment(
        # TODO based on Threads
        is_reply = false,
        # TODO include socket __context__
        context
      )
  end

  def all_text_content(attrs, changeset) do
    "#{get_attr(attrs, changeset, :name)}\n#{get_attr(attrs, changeset, :summary)}\n#{get_attr(attrs, changeset, :html_body)}\n#{get_attr(attrs, changeset, :note)}"
    |> debug()
  end

  defp get_attr(attrs, changeset, key) do
    ed(changeset, :changes, :post_content, :changes, key, nil) || ed(attrs, key, nil) ||
      ed(attrs, :post, :post_content, key, nil) ||
      ed(attrs, :post_content, key, nil) || ed(attrs, :post, key, nil) || ed(attrs, key, nil)
  end
end
