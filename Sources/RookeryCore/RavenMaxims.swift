import Foundation

/// A saying of the ancient Greeks, as the launcher shows one beside Raven before anything is typed.
public struct Maxim: Equatable, Sendable {
    public let text: String
    /// Who said it, or where it comes from.
    public let author: String

    public init(text: String, author: String) {
        self.text = text
        self.author = author
    }
}

/// The sayings the launcher picks from: Greek philosophers and sages, each with its source as the ancient
/// writers give it, short enough for one row.
public enum RavenMaxims {
    public static let listMaxims: [Maxim] = [
        Maxim(text: "Know thyself.", author: "Delphic maxim"),
        Maxim(text: "Nothing in excess.", author: "Delphic maxim"),
        Maxim(text: "Know your opportunity.", author: "Pittacus"),
        Maxim(text: "Measure is best.", author: "Cleobulus"),
        Maxim(text: "Practice is everything.", author: "Periander"),
        Maxim(text: "Make haste slowly.", author: "Greek proverb"),
        Maxim(text: "The unexamined life is not worth living.", author: "Socrates"),
        Maxim(text: "Wonder is the beginning of wisdom.", author: "Socrates"),
        Maxim(text: "I know that I know nothing.", author: "Socrates"),
        Maxim(text: "The beginning is the most important part of the work.", author: "Plato"),
        Maxim(text: "Let no one ignorant of geometry enter.", author: "Plato's Academy"),
        Maxim(text: "Well begun is half done.", author: "Aristotle"),
        Maxim(text: "A friend is another self.", author: "Aristotle"),
        Maxim(text: "Nature does nothing in vain.", author: "Aristotle"),
        Maxim(text: "Hope is a waking dream.", author: "Aristotle"),
        Maxim(text: "The roots of education are bitter, but the fruit is sweet.", author: "Aristotle"),
        Maxim(text: "Happiness depends upon ourselves.", author: "Aristotle"),
        Maxim(text: "No one steps into the same river twice.", author: "Heraclitus"),
        Maxim(text: "Character is destiny.", author: "Heraclitus"),
        Maxim(text: "The way up and the way down are one and the same.", author: "Heraclitus"),
        Maxim(text: "Much learning does not teach understanding.", author: "Heraclitus"),
        Maxim(text: "Even sleepers are workers in what goes on in the world.", author: "Heraclitus"),
        Maxim(text: "Time is the wisest of all things, for it brings everything to light.", author: "Thales"),
        Maxim(text: "The hardest thing is to know yourself; the easiest, to advise another.", author: "Thales"),
        Maxim(text: "Man is the measure of all things.", author: "Protagoras"),
        Maxim(text: "Give me a place to stand, and I will move the earth.", author: "Archimedes"),
        Maxim(text: "Do not disturb my circles.", author: "Archimedes"),
        Maxim(text: "There is no royal road to geometry.", author: "Euclid"),
        Maxim(text: "It is not things that disturb us, but our judgments about them.", author: "Epictetus"),
        Maxim(text: "First say to yourself what you would be; then do what you have to do.", author: "Epictetus"),
        Maxim(text: "No one is free who is not master of himself.", author: "Epictetus"),
        Maxim(text: "Wealth is not in great possessions, but in few wants.", author: "Epictetus"),
        Maxim(text: "What stands in the way becomes the way.", author: "Marcus Aurelius"),
        Maxim(text: "Waste no more time arguing what a good man should be. Be one.", author: "Marcus Aurelius"),
        Maxim(text: "The happiness of your life depends upon the quality of your thoughts.", author: "Marcus Aurelius"),
        Maxim(text: "Do not spoil what you have by desiring what you have not.", author: "Epicurus"),
        Maxim(text: "Not what we have, but what we enjoy, makes our abundance.", author: "Epicurus"),
        Maxim(text: "From nothing, nothing comes.", author: "Parmenides"),
        Maxim(text: "Everything flows.", author: "Simplicius on Heraclitus"),
        Maxim(text: "Learning is not the filling of a pail, but the kindling of a fire.", author: "Plutarch"),
    ]

    /// A saying picked at random.
    public static func random<Generator: RandomNumberGenerator>(using generator: inout Generator) -> Maxim {
        listMaxims.randomElement(using: &generator) ?? listMaxims[0]
    }

    /// A saying picked at random.
    public static func random() -> Maxim {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}
