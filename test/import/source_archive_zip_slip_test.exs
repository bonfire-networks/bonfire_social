defmodule Bonfire.Social.Import.SourceArchiveZipSlipTest do
  @moduledoc "An uploaded account archive that holds a file named to land outside its folder (`../x`, an absolute path) is refused before anything is read or written."
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Import.Source.Archive

  @moduletag :backend

  @following "Account address,Show boosts\nsomeone@remote.local,true\n"

  defp zip!(entries) do
    dir = Path.join(System.tmp_dir!(), "zip_slip_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "archive.zip")

    {:ok, _} =
      :zip.create(
        String.to_charlist(path),
        for({name, data} <- entries, do: {String.to_charlist(name), data})
      )

    {path, dir}
  end

  test "control: an archive of plain file names is staged" do
    {path, _dir} = zip!([{"following.csv", @following}])

    assert {:ok, %{dir: dir}} = Archive.stage(path)
    on_exit(fn -> File.rm_rf(dir) end)
  end

  for {label, name} <- [
        {"a parent directory", "../outside.txt"},
        {"a nested parent directory", "folder/../../outside.txt"}
      ] do
    test "an entry named with #{label} is refused" do
      {path, dir} = zip!([{"following.csv", @following}, {unquote(name), "x"}])

      assert {:error, _} = Archive.stage(path)

      refute File.exists?(Path.join(Path.dirname(dir), "outside.txt"))
      refute File.exists?("/tmp/outside.txt")
    end
  end
end
