package com.galaxycallbridge.diagnostics;

import java.util.ArrayList;
import java.util.List;

/** Pure parser (no Android deps) for the ringing caller number in a telephony.registry dump. Never logs. */
final class IncomingNumber {
    private IncomingNumber() { }

    /** Returns the caller number of a ringing phone slot, or null when absent or unusable. */
    static String parse(String dump) {
        if (dump == null) return null;
        List<Integer> states = new ArrayList<>();
        List<String> numbers = new ArrayList<>();
        for (String line : dump.split("\n")) {
            String text = line.trim();
            if (text.startsWith("mCallState=")) {
                try { states.add(Integer.parseInt(text.substring(11).trim())); }
                catch (NumberFormatException ignored) { states.add(-1); }
            } else if (text.startsWith("mCallIncomingNumber=")) {
                numbers.add(sanitize(text.substring(20)));
            }
        }
        // Per-slot arrays are dumped in the same order; pair them so another slot's value is never used.
        if (states.size() == numbers.size()) {
            for (int i = 0; i < states.size(); i++) if (states.get(i) == 1 && numbers.get(i) != null) return numbers.get(i);
            return null;
        }
        for (String number : numbers) if (number != null) return number;
        return null;
    }

    /** Keeps only dial-string characters; anything else (including "null" or redaction text) is no number. */
    static String sanitize(String raw) {
        String value = raw == null ? "" : raw.trim();
        if (value.isEmpty() || value.length() > 32) return null;
        int digits = 0;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c >= '0' && c <= '9') digits++;
            else if (!(c == '+' || c == '*' || c == '#' || c == ' ' || c == '-' || c == '(' || c == ')')) return null;
        }
        return digits > 0 ? value : null;
    }
}
