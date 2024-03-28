#!/usr/bin/env python
# encoding: utf-8
import json
import robot
from flask import Flask, jsonify, request

app = Flask(__name__)


def giga_executor_2000():
    pass


@app.route("/", methods=["POST"])
def index():
    if request.method == "POST":
        f = open("./testfile.robot", "w")
        json_request = json.loads(request.data)
        f.write(json_request["data"])
        f.close()
        if robot.run("./testfile.robot") != 0:
            return {"status": "error"}
    return {"status": "ok"}


@app.route("/report")
def get_report():
    try:
        f = open("./report.html", "r")
        report = f.read()
        f.close()
    except FileNotFoundError:
        return "not found", 404
    return report


@app.route("/log")
def get_log():
    try:
        f = open("./log.html", "r")
        log = f.read()
        f.close()
    except FileNotFoundError:
        return "not found", 404
    return log


app.run(debug=True, port=8001, host="0.0.0.0")
