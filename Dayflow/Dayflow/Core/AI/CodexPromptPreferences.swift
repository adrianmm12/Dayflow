//
//  CodexPromptPreferences.swift
//  Dayflow
//
//  Compatibility aliases. The shared prompt preference/section/default
//  machinery moved verbatim to TimelinePromptPreferences.swift under
//  provider-neutral names. The historical UserDefaults key
//  ("chatGPTPromptOverrides") and all stored values are unchanged.
//

import Foundation

typealias CodexPromptPreferences = TimelinePromptPreferences
typealias CodexPromptDefaults = TimelinePromptDefaults
typealias CodexPromptSections = TimelinePromptSections
