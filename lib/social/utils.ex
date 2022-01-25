defmodule Bonfire.Social.Utils do

  use Arrows
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Utils
  alias Bonfire.Me.{Acls, Users.Circles}
  alias Bonfire.Repo

  defp get_user_acls(user) do
    Acls.list(current_user: user, skip_boundary_check: true)
    |> Repo.preload([:grants])
  end    

  defp get_object_acls(object) do
    Repo.preload(object, [controlled: [acl: [:stereotype, :named, :grants]]]).controlled
    |> Enum.map(&(&1.acl))
  end

  def debug_user_circles(user) do
    user = Repo.preload user, [encircles: [circle: [:named]]]
    IO.puts "User: #{user.id}"
    for encircle <- user.encircles do
      %{circle_id: encircle.circle_id,
        circle_name: Utils.e(encircle.circle, :named, :name, nil),
      }
    end
    |> Scribe.print()
  end

  def debug_user_acls(user) do
    acls = get_user_acls(user)
    IO.puts "User: #{user.id}"
    debug_acls(acls)
  end

  defp debug_acls(acls) do
    for acl <- acls,
        grant <- acl.grants do
      %{acl_id: acl.id,
        acl_name: Utils.e(acl, :named, :name, nil),
        acl_stereotype: Utils.e(acl, :stereotype, :stereotype_id, nil),
        grant_verb: Verbs.get!(grant.verb_id).verb,
        grant_subject: grant.subject_id,
        grant_value: grant.value,
      }
    end
    |> Enum.group_by(&{&1.acl_id, &1.grant_subject, &1.grant_value})
    |> for({k, [v|_]=vs} <- ...) do
      Map.put(v, :grant_verb, Enum.sort(Enum.map(vs, &(&1.grant_verb))))
    end
    |> Scribe.print()
  end

  def debug_object_acls(thing) do
    acls = get_object_acls(thing)
    IO.puts "Object: #{thing.id}"
    debug_acls(acls)
  end

end
