defmodule Bonfire.Social.Test.FakeHelpers do
  import Tesla.Mock

  # Helper to setup Tesla mocks for URL metadata
  def setup_url_mocks do
    mock(fn
      %{method: :get, url: "https://example.com/article1"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Article 1 - Great Content</title></head></html>"
        }

      %{method: :get, url: "https://example.com/article2"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Article 2 - Different Topic</title></head></html>"
        }

      %{method: :get, url: "https://example.com/old"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Old Article</title></head></html>"
        }

      %{method: :get, url: "https://example.com/popular"} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Very Popular Article</title></head></html>"
        }

      %{method: :get, url: "https://example.com/" <> _} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: "<html><head><title>Generic Article</title></head></html>"
        }
    end)
  end
end
