// herd's dialogs, drawn like the app's prompt and confirm. The app's prompt hands its text to an
// app command, and <mod>.<command>s get only a string, so herd's forms send their answers back
// to the panel as "herd.<name>:<json>" (lib.js encode). Props, by kind:
//   form  { title, hint?, fields: [{ key, label, value?, placeholder? }], choices?: { field, items },
//           submit: { name, label } }        Enter or the button: every field must be filled
//   pick  { title, items, command }          ↑↓ Enter or a click: sends the item
//   log   { title, text, ok }                a job's output
import { div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input, Scrollbar } from "gpui-base";
import { run, props, closeOverlay, theme, settings } from "herdr";
import { encode } from "./lib.js";

export class Dialog {
  init(cx) {
    const p = props() ?? {};
    this.kind = p.dialog;
    this.handle = cx.focus_handle();
    this.error = "";
    this.at = 0;
    this.inputs = (p.fields ?? []).map((f) => {
      const s = InputState.new({ value: f.value ?? "", placeholder: f.placeholder ?? "" });
      const field = { ...f, state: s, focused: false };
      s.on("change", (_e, cx) => { this.error = ""; cx.notify(); });
      s.on("submit", () => this.submit());
      s.on("focus", (_e, cx) => { field.focused = true; cx.notify(); });
      s.on("blur", (_e, cx) => { field.focused = false; cx.notify(); });
      return field;
    });
    const first = this.inputs.find((f) => !f.value) ?? this.inputs[0];
    if (first) { first.state.focus(); cx.timer.after(600, () => first.state.focus()); }
    else { this.handle.focus(); cx.timer.after(300, () => this.handle.focus()); }
  }

  close() { closeOverlay(props().overlay); }

  submit() {
    const p = props();
    const data = {};
    for (const f of this.inputs) data[f.key] = f.state.value().trim();
    const missing = this.inputs.find((f) => !data[f.key]);
    if (missing) { this.error = `${missing.label.split(":")[0]} is empty.`; return; }
    this.close();
    run(encode(p.submit.name, data));
  }

  pick(item) {
    if (item === undefined) return;
    this.close();
    run(encode(props().command, item));
  }

  key(e, cx) {
    const items = props()?.items ?? [];
    if (e.key === "escape") this.close();
    else if (this.kind === "pick" && e.key === "enter") this.pick(items[this.at]);
    else if (this.kind === "pick" && (e.key === "down" || e.key === "up") && items.length) {
      this.at = (this.at + (e.key === "down" ? 1 : items.length - 1)) % items.length;
    } else if (this.kind === "log" && e.key === "enter") this.close();
    else if (this.kind === "form" && e.key === "tab" && this.inputs.length > 1) {
      const i = this.inputs.findIndex((f) => f.focused);
      this.inputs[(i + (e.modifiers?.shift ? this.inputs.length - 1 : 1)) % this.inputs.length].state.focus();
    } else return;
    cx.stop_propagation();
    cx.notify();
  }

  button(id, text, primary, action) {
    const t = theme();
    return h_flex().id(id).h(32).px(14).items_center().rounded(8).border_1().border_color(primary ? t.solid : t.input)
      .bg(primary ? t.solid : t.raised).text_color(primary ? t.solid_foreground : t.foreground).text_size(12.5).font_medium()
      .cursor_pointer().hover((s) => s.opacity(0.88)).on_click(action).child(text);
  }

  title(text, t) {
    return h_flex().flex_none().items_center()
      .child(div().flex_1().min_w(0).truncate().text_size(15).font_semibold().child(text ?? ""))
      .child(div().text_size(11).text_color(t.dim).child("Esc"));
  }

  form(p, t) {
    const choices = p.choices?.items ?? [];
    const target = this.inputs.find((f) => f.key === p.choices?.field);
    return v_flex().id("herd-form").flex_1().min_h(0)
      .children(this.inputs.map((f) => v_flex().flex_none()
        .child(div().pt(14).pb(6).text_size(11.5).text_color(t.dim).child(f.label))
        .child(Input.new(f.state).h(34).px(10).rounded(8).border_1().border_color(f.focused ? t.accent : t.input)
          .bg(t.background).text_size(12.8).text_color(t.foreground))))
      .when(choices.length > 0 && Boolean(target), (el) => el.child(
        h_flex().flex_none().pt(8).gap(6).flex_wrap().children(choices.slice(0, 8).map((c, i) =>
          div().id(`choice-${i}`).px(8).py(3).rounded(6).border_1().border_color(t.border).text_size(11.5).text_color(t.muted)
            .cursor_pointer().hover((s) => s.bg(t.hover).text_color(t.foreground))
            .on_click((_e, cx) => { target.state.set_value(c); target.state.focus(); cx.notify(); }).child(c)))))
      .when(Boolean(p.hint), (el) => el.child(div().pt(10).text_size(11.5).text_color(t.dim).child(p.hint)))
      .when(Boolean(this.error), (el) => el.child(div().pt(8).text_size(12).text_color(t.blocked).child(this.error)))
      .child(div().flex_1())
      .child(h_flex().flex_none().pt(16).gap(8).justify_end()
        .child(this.button("herd-cancel", "Cancel", false, () => this.close()))
        .child(this.button("herd-submit", p.submit?.label ?? "OK", true, () => this.submit())));
  }

  list(p, t) {
    const items = p.items ?? [];
    return v_flex().flex_1().min_h(0).pt(12).gap(8)
      .child(div().flex_1().min_h(0).relative()
        .child(v_flex().id("herd-pick").absolute().inset_0().overflow_y_scroll().children(items.map((it, i) =>
          h_flex().id(`pick-${i}`).flex_none().h(32).px(10).items_center().rounded(7).cursor_pointer()
            .when(i === this.at, (el) => el.bg(t.selected)).when(i !== this.at, (el) => el.hover((s) => s.bg(t.hover)))
            .on_click(() => this.pick(it)).child(div().truncate().child(it)))))
        .child(Scrollbar.vertical("herd-pick").absolute().inset_0()))
      .child(h_flex().flex_none().justify_end().text_size(11).text_color(t.dim).child("↑↓ choose · ↵ pick · esc close"));
  }

  log(p, t) {
    const lines = (p.text ?? "").split("\n");
    return v_flex().flex_1().min_h(0).pt(12).gap(10)
      .child(div().flex_1().min_h(0).relative().rounded(8).border_1().border_color(t.border).bg(t.background)
        .child(v_flex().id("herd-log").absolute().inset_0().overflow_y_scroll().p(10)
          .font_family(settings().font_family ?? "JetBrains Mono").text_size(11.5).text_color(p.ok ? t.foreground : t.muted)
          .children(lines.map((l, i) => div().id(`log-${i}`).flex_none().child(l || " "))))
        .child(Scrollbar.vertical("herd-log").absolute().inset_0()))
      .child(h_flex().flex_none().justify_end().child(this.button("herd-close", "Close", true, () => this.close())));
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const body = this.kind === "form" ? this.form(p, t) : this.kind === "pick" ? this.list(p, t) : this.log(p, t);
    return v_flex().id("herd-dialog").track_focus(this.handle).on_key_down((e, cx) => this.key(e, cx))
      .size_full().min_h(0).p(18).bg(t.popover).text_color(t.foreground).text_size(13)
      .child(this.title(p.title, t))
      .child(body);
  }
}
