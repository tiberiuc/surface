defmodule Surface.ComponentChangeTrackingTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Endpoint

  defmodule Comp do
    use Surface.Component

    prop id, :string, required: true

    prop value, :integer, default: 0

    prop context, :any

    def render(assigns) do
      ~F"""
      Component {@id}, Value: {@value}, Context: {@context}, Rendering: {:erlang.unique_integer([:positive])}
      """
    end
  end

  defmodule View do
    use Surface.LiveView

    data count_1, :integer, default: 0
    data count_2, :integer, default: 0
    data context, :any, default: "fake_context"

    # Required to test the stateful component
    data test_pid, :integer

    alias Surface.CheckUpdated

    def mount(_params, %{"test_pid" => test_pid}, socket) do
      {:ok, assign(socket, test_pid: test_pid)}
    end

    def render(assigns) do
      ~F"""
      {!-- Simulates the use of contexts --}
      {#case {:default, 0, @context}}
        {#match {_slot, _slot_index, context}}
          {!-- Set the value of the context variable into the @context assign --}
          {assign(assigns, :context, context) && ""}
          {!-- By passing the @context instead of a variable, we no longer disable change tracking :) --}
          <Comp id="comp_1" value={@count_1} context={@context}/>
          <Comp id="comp_2" value={@count_2} context={@context}/>
          <CheckUpdated id="stateful_comp" dest={@test_pid} content={@context}/>
      {/case}
      """
    end

    def handle_event("update_count", %{"comp" => id, "value" => value}, socket) do
      {:noreply, assign(socket, String.to_atom("count_#{id}"), value)}
    end

    def handle_event("update_context", %{"value" => value}, socket) do
      {:noreply, assign(socket, :context, value)}
    end
  end

  test "change tracking" do
    # Initial values

    {:ok, view, html} = live_isolated(build_conn(), View, session: %{"test_pid" => self()})
    result_1 = parse_result(html)
    assert result_1["comp_1"].value == 0
    assert result_1["comp_1"].context == "fake_context"
    assert result_1["comp_2"].context == "fake_context"
    assert_receive {:updated, "stateful_comp"}

    # Don't rerender components if their props haven't change

    html = render_click(view, :update_count, %{comp: "1", value: 0})
    assert parse_result(html) == result_1
    html = render_click(view, :update_count, %{comp: "2", value: 0})
    assert parse_result(html) == result_1
    refute_receive {:updated, "stateful_comp"}

    # Only rerender components with changed props

    html = render_click(view, :update_count, %{comp: "1", value: 1})
    result_3 = parse_result(html)
    assert result_3["comp_1"].value == 1
    assert result_3["comp_1"].rendering != result_1["comp_1"].rendering
    assert result_3["comp_2"] == result_1["comp_2"]
    refute_receive {:updated, "stateful_comp"}

    html = render_click(view, :update_count, %{comp: "2", value: 1})
    result_4 = parse_result(html)
    assert result_4["comp_1"] == result_3["comp_1"]
    assert result_4["comp_2"].value == 1
    assert result_4["comp_2"].rendering != result_3["comp_2"].rendering
    refute_receive {:updated, "stateful_comp"}

    # Don't rerender components if context hasn't change

    html = render_click(view, :update_context, %{value: "fake_context"})
    assert parse_result(html) == result_4
    refute_receive {:updated, "stateful_comp"}

    # Only rerender components if the context changes

    assert result_4["comp_1"].context == "fake_context"
    assert result_4["comp_2"].context == "fake_context"

    html = render_click(view, :update_context, %{value: "changed_fake_context"})
    result_5 = parse_result(html)
    assert result_5["comp_1"].rendering != result_4["comp_1"].rendering
    assert result_5["comp_2"].rendering != result_4["comp_2"].rendering
    assert result_5["comp_1"].context == "changed_fake_context"
    assert result_5["comp_2"].context == "changed_fake_context"
    assert_receive {:updated, "stateful_comp"}
  end

  defp parse_result(html) do
    mapper = fn [_, id, value, context, rendering] ->
      {id, %{value: String.to_integer(value), context: context, rendering: String.to_integer(rendering)}}
    end

    Regex.scan(~r/Component (.+?), Value: (\d+), Context: (.+?), Rendering: (\d+)/, html) |> Map.new(mapper)
  end
end
