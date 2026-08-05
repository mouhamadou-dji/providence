local Enums = {}

Enums.Race = {
    Human = "Human",
    Vampire = "Vampire",
    Dwarf = "Dwarf",
    Apostle = "Apostle",
    GodHand = "GodHand",
}

Enums.Relation = {
    Brother = "Brother",
    Sister = "Sister",
    Twin = "Twin",
    Cousin = "Cousin",
    DistantRelative = "DistantRelative",
    None = "None",
}

Enums.PlayerState = {
    Alive = "Alive",
    Dead = "Dead",
}

Enums.ParryResult = {
    Perfect = "Perfect",
    Late = "Late",
    Whiff = "Whiff",
    Break = "Break",
}

Enums.WeaponType = {
    Longsword = "Longsword",
    Spear = "Spear",
    Axe = "Axe",
    Dagger = "Dagger",
    Fists = "Fists",
}

Enums.WeaponQuality = {
    Iron = 1,
    Steel = 2,
    Masterwork = 3,
    Legendary = 4,
    Divine = 5,
}

Enums.Weather = {
    Clear = "Clear",
    Fog = "Fog",
    Rain = "Rain",
    Storm = "Storm",
    BloodRain = "BloodRain",
    Earthquake = "Earthquake",
}

Enums.CombatState = {
    Idle = "Idle",
    Attacking = "Attacking",
    Parrying = "Parrying",
    Blocking = "Blocking",
    Staggered = "Staggered",
    GuardBroken = "GuardBroken",
    Clashing = "Clashing",
    Downed = "Downed",
    Executing = "Executing",
    BeingExecuted = "BeingExecuted",
    Carrying = "Carrying",
    BeingCarried = "BeingCarried",
    Dead = "Dead",
}

Enums.Currency = {
    Obol = "Obol",
    Drachma = "Drachma",
    Stater = "Stater",
    RoyalStater = "RoyalStater",
}

return Enums