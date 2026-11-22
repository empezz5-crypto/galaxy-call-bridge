package com.galaxycallbridge.diagnostics;

/** Offline check of the caller-number parser: javac -d OUT companion-diagnostics/src/main/java/com/galaxycallbridge/diagnostics/IncomingNumber.java tests/IncomingNumberChecks.java; java -cp OUT com.galaxycallbridge.diagnostics.IncomingNumberChecks */
public final class IncomingNumberChecks {
    public static void main(String[] a) throws Exception {
        String ring = "  Phone Id=0\n    mCallState=1\n    mCallIncomingNumber=010-1234-5678\n  Phone Id=1\n    mCallState=0\n    mCallIncomingNumber=\n";
        eq("010-1234-5678", IncomingNumber.parse(ring), "ringing slot number");
        eq(null, IncomingNumber.parse("mCallState=0\nmCallIncomingNumber=01011112222\n"), "idle slot ignored (stale)");
        eq("+821012345678", IncomingNumber.parse("mCallState=0\nmCallIncomingNumber=\nmCallState=1\nmCallIncomingNumber=+821012345678\n"), "second slot ringing");
        eq(null, IncomingNumber.parse("mCallState=1\nmCallIncomingNumber=\n"), "private number is null");
        eq(null, IncomingNumber.parse("mCallState=1\nmCallIncomingNumber=null\n"), "text value is null");
        eq(null, IncomingNumber.parse("mCallState=1\nmCallIncomingNumber=[redacted]\n"), "redaction is null");
        eq(null, IncomingNumber.parse(null), "null dump");
        eq(null, IncomingNumber.parse("nothing here"), "no fields");
        eq("114", IncomingNumber.parse("mCallState=1\nmCallIncomingNumber=114\n"), "short caller id kept");
        eq(null, IncomingNumber.parse("mCallState=1\nmCallIncomingNumber=" + "1".repeat(40) + "\n"), "overlong rejected");
        eq("0212345678", IncomingNumber.parse("mCallIncomingNumber=0212345678\n"), "unpaired falls back to first number");
        System.out.println("PASS IncomingNumberChecks");
    }
    static void eq(String want, String got, String label) {
        if (want == null ? got != null : !want.equals(got)) { System.err.println("FAIL: " + label + " got=" + got); System.exit(1); }
        System.out.println("PASS: " + label);
    }
}
