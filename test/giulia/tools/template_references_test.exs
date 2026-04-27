defmodule Giulia.Tools.TemplateReferencesTest do
  use ExUnit.Case, async: true

  alias Giulia.Tools.TemplateReferences

  defp with_project(files, callback) do
    dir = Path.join(System.tmp_dir!(), "tpl_refs_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    try do
      for {rel, content} <- files do
        path = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end

      callback.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  describe "scan/1" do
    test "returns empty maps when project has no templates" do
      with_project(%{"README.md" => "hi"}, fn dir ->
        result = TemplateReferences.scan(dir)
        assert MapSet.size(result.qualified) == 0
        assert result.local_per_file == %{}
      end)
    end

    test "extracts qualified function reference from HEEx curly interpolation" do
      with_project(
        %{
          "lib/my_app_web/templates/page/index.html.heex" => """
          <div>{MyApp.Helpers.format(@x)}</div>
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          assert "MyApp.Helpers.format" in result.qualified
        end
      )
    end

    test "extracts qualified function reference from old-style EEx interpolation" do
      with_project(
        %{
          "lib/foo/template.eex" => """
          <%= MyApp.Helpers.greet(@name) %>
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          assert "MyApp.Helpers.greet" in result.qualified
        end
      )
    end

    test "extracts qualified component invocation <Mod.Sub.fn>" do
      with_project(
        %{
          "lib/my_app_web/templates/foo/bar.html.heex" => """
          <MyAppWeb.Components.Card title="x">body</MyAppWeb.Components.Card>
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          assert "MyAppWeb.Components.Card" in result.qualified
        end
      )
    end

    test "extracts capture &Mod.fn/N from expressions" do
      with_project(
        %{
          "lib/foo/template.eex" => """
          <%= Enum.map(@list, &MyApp.Helpers.format/1) %>
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          assert "MyApp.Helpers.format" in result.qualified
          # Enum.map also matches as a qualified ref — that's fine, harmless
        end
      )
    end

    test "extracts local fn refs into local_per_file map" do
      with_project(
        %{
          "lib/my_app_web/templates/layout/email.html.heex" => """
          <a href={plausible_url()}>{plausible_url()}</a>
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          file = Path.join(dir, "lib/my_app_web/templates/layout/email.html.heex")
          assert "plausible_url" in result.local_per_file[file]
        end
      )
    end

    test "extracts local component <.fn> as local ref" do
      with_project(
        %{
          "lib/my_app_web/components/layouts/app.html.heex" => """
          <.flash_group flash={@flash} />
          {@inner_content}
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          file = Path.join(dir, "lib/my_app_web/components/layouts/app.html.heex")
          assert "flash_group" in result.local_per_file[file]
        end
      )
    end

    test "skips Elixir keywords from local refs" do
      with_project(
        %{
          "lib/x.heex" => """
          <%= if @show do %>
            <p>visible</p>
          <% end %>
          """
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          locals = result.local_per_file |> Map.values() |> Enum.flat_map(&MapSet.to_list/1)
          refute "if" in locals
          refute "do" in locals
          refute "end" in locals
        end
      )
    end

    test "scans both .heex and .eex extensions" do
      with_project(
        %{
          "lib/a.heex" => "<div>{MyApp.A.func()}</div>",
          "lib/b.eex" => "<%= MyApp.B.func() %>"
        },
        fn dir ->
          result = TemplateReferences.scan(dir)
          assert "MyApp.A.func" in result.qualified
          assert "MyApp.B.func" in result.qualified
        end
      )
    end
  end

  describe "conventional_view_module/2" do
    test "older Phoenix templates/<view>/<file>.html.heex → <App>Web.<View>View" do
      assert TemplateReferences.conventional_view_module(
               "/proj/lib/plausible_web/templates/layout/email.html.heex",
               %{}
             ) == "PlausibleWeb.LayoutView"
    end

    test "older Phoenix with multi-segment app name" do
      assert TemplateReferences.conventional_view_module(
               "/proj/lib/my_app_web/templates/site/new.html.heex",
               %{}
             ) == "MyAppWeb.SiteView"
    end

    test "colocated LiveView template — strips .html.heex, looks up .ex sibling in module_index" do
      module_index = %{
        "/proj/lib/foo_web/live/admin_live/cluster.ex" => "FooWeb.AdminLive.Cluster"
      }

      assert TemplateReferences.conventional_view_module(
               "/proj/lib/foo_web/live/admin_live/cluster.html.heex",
               module_index
             ) == "FooWeb.AdminLive.Cluster"
    end

    test "returns nil when neither convention matches" do
      assert TemplateReferences.conventional_view_module(
               "/random/path/template.heex",
               %{}
             ) == nil
    end
  end
end
